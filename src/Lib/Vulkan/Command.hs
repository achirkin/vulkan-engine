{-# LANGUAGE Strict           #-}
module Lib.Vulkan.Command
  ( createCommandPool
  , allocateCommandBuffers
  , allocateCommandBuffer
  , runCommandsAsync
  , runCommandsOnce
  ) where

import           Control.Concurrent
import           Control.Exception                        (throw)
import           Graphics.Vulkan
import           Graphics.Vulkan.Core_1_0
import           Graphics.Vulkan.Marshal.Create
import           Graphics.Vulkan.Marshal.Create.DataFrame
import           Numeric.DataFrame

import           Lib.Program
import           Lib.Program.Foreign
import           Lib.Vulkan.Device
import           Lib.Vulkan.Sync


createCommandPool :: VkDevice -> DevQueues -> Program r VkCommandPool
createCommandPool dev DevQueues{..} =
  allocResource (liftIO . flip (vkDestroyCommandPool dev) VK_NULL) $
    allocaPeek $ \pPtr -> withVkPtr
      ( createVk
        $  set @"sType" VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* set @"flags" VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
        &* set @"queueFamilyIndex" graphicsFamIdx
      ) $ \ciPtr -> runVk $ vkCreateCommandPool dev ciPtr VK_NULL pPtr


-- TODO return in dataframe?
allocateCommandBuffers :: VkDevice
                       -> VkCommandPool
                       -> Int
                       -> Program r [VkCommandBuffer]
allocateCommandBuffers dev cmdPool buffersCount = do
  -- allocate a pointer to an array of command buffer handles
  cbsPtr <- mallocArrayRes buffersCount

  allocResource
    (const $ liftIO $
      vkFreeCommandBuffers dev cmdPool (fromIntegral buffersCount) cbsPtr)
    $ do
    let allocInfo = createVk @VkCommandBufferAllocateInfo
          $  set @"sType" VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
          &* set @"pNext" VK_NULL
          &* set @"commandPool" cmdPool
          &* set @"level" VK_COMMAND_BUFFER_LEVEL_PRIMARY
          &* set @"commandBufferCount" (fromIntegral buffersCount)

    withVkPtr allocInfo $ \aiPtr ->
      runVk $ vkAllocateCommandBuffers dev aiPtr cbsPtr
    peekArray buffersCount cbsPtr


allocateCommandBuffer :: VkDevice
                      -> VkCommandPool
                      -> Program r VkCommandBuffer
allocateCommandBuffer dev cmdPool = do
  bufs <- allocateCommandBuffers dev cmdPool 1
  return $ head bufs


-- | Starts in separate thread, but waits until command buffer has been submitted
--
--   Deferres deallocation of resources until execution by the queue is done.
runCommandsAsync :: VkDevice
                 -> VkCommandPool
                 -> VkQueue
                 -> (VkCommandBuffer -> Program () a)
                 -> Program r a
runCommandsAsync dev cmdPool cmdQueue action = do
  fin <- liftIO newEmptyMVar
  _ <- liftIO $ forkIO $ runProgram (\res -> tryPutMVar fin res >> return ()) $ do
    -- create command buffer
    let allocInfo = createVk @VkCommandBufferAllocateInfo
          $  set @"sType" VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
          &* set @"level" VK_COMMAND_BUFFER_LEVEL_PRIMARY
          &* set @"commandPool" cmdPool
          &* set @"commandBufferCount" 1
          &* set @"pNext" VK_NULL

    cmdBufs <- allocResource
      (liftIO . flip withDFPtr (vkFreeCommandBuffers dev cmdPool 1))
      (withVkPtr allocInfo $ \aiPtr -> allocaPeekDF $ runVk . vkAllocateCommandBuffers dev aiPtr)
    -- record command buffer
    let cmdbBI = createVk @VkCommandBufferBeginInfo
          $  set @"sType" VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
          &* set @"flags" VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
          &* set @"pNext" VK_NULL
        cmdBuf = unScalar cmdBufs
    withVkPtr cmdbBI $ runVk . vkBeginCommandBuffer cmdBuf
    result <- action cmdBuf
    runVk $ vkEndCommandBuffer cmdBuf

    -- execute command in a give queue
    let submitInfo = createVk @VkSubmitInfo
          $  set @"sType" VK_STRUCTURE_TYPE_SUBMIT_INFO
          &* set @"pNext" VK_NULL
          &* set @"waitSemaphoreCount" 0
          &* set @"pWaitSemaphores"   VK_NULL
          &* set @"pWaitDstStageMask" VK_NULL
          &* set @"commandBufferCount" 1
          &* setDFRef @"pCommandBuffers" cmdBufs
          &* set @"signalSemaphoreCount" 0
          &* set @"pSignalSemaphores" VK_NULL

    fence <- createFence dev False
    withVkPtr submitInfo $ \siPtr ->
      runVk $ vkQueueSubmit cmdQueue 1 siPtr fence
    _ <- liftIO $ tryPutMVar fin $ Right result
    fencePtr <- newArrayRes [fence]
    runVk $ vkWaitForFences dev 1 fencePtr VK_TRUE (maxBound :: Word64)
    return result

  result <- liftIO $ takeMVar fin
  case result of
    Left except -> throw except
    Right x     -> return x


runCommandsOnce :: VkDevice
                -> VkCommandPool
                -> VkQueue
                -> (VkCommandBuffer -> Program r a)
                -> Program r a
runCommandsOnce dev cmdPool cmdQueue action = do
    -- create command buffer
    let allocInfo = createVk @VkCommandBufferAllocateInfo
          $  set @"sType" VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
          &* set @"level" VK_COMMAND_BUFFER_LEVEL_PRIMARY
          &* set @"commandPool" cmdPool
          &* set @"commandBufferCount" 1
          &* set @"pNext" VK_NULL

    bracket
      (withVkPtr allocInfo $ \aiPtr -> allocaPeekDF $
          runVk . vkAllocateCommandBuffers dev aiPtr)
      (liftIO . flip withDFPtr (vkFreeCommandBuffers dev cmdPool 1))
      $ \cmdBufs -> do
        -- record command buffer
        let cmdbBI = createVk @VkCommandBufferBeginInfo
              $  set @"sType" VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
              &* set @"flags" VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
              &* set @"pNext" VK_NULL
            cmdBuf = unScalar cmdBufs
        withVkPtr cmdbBI $ runVk . vkBeginCommandBuffer cmdBuf
        result <- action cmdBuf
        runVk $ vkEndCommandBuffer cmdBuf

        -- execute command in a give queue
        let submitInfo = createVk @VkSubmitInfo
              $  set @"sType" VK_STRUCTURE_TYPE_SUBMIT_INFO
              &* set @"pNext" VK_NULL
              &* set @"waitSemaphoreCount" 0
              &* set @"pWaitSemaphores"   VK_NULL
              &* set @"pWaitDstStageMask" VK_NULL
              &* set @"commandBufferCount" 1
              &* setDFRef @"pCommandBuffers" cmdBufs
              &* set @"signalSemaphoreCount" 0
              &* set @"pSignalSemaphores" VK_NULL
        locally $ do
          -- TODO maybe add a param if it should wait here, or submit a
          -- different fence that is waited for elsewhere, or whatever
          fence <- createFence dev False
          withVkPtr submitInfo $ \siPtr ->
            runVk $ vkQueueSubmit cmdQueue 1 siPtr fence
          fencePtr <- newArrayRes [fence]
          runVk $ vkWaitForFences dev 1 fencePtr VK_TRUE (maxBound :: Word64)
        return result
