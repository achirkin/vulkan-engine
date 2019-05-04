{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Strict              #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
module Lib
  ( runVulkanProgram
  , WhichDemo (..)
  ) where

import           Control.Monad                        (forM_, when)
import           Data.IORef
import           Data.Maybe                           (fromJust)
import           Graphics.Vulkan.Core_1_0
import           Graphics.Vulkan.Ext.VK_KHR_swapchain
import           Numeric.DataFrame
import           Numeric.Dimensions
import           System.Directory                     (doesFileExist)

import           Lib.GLFW
import           Lib.Program
import           Lib.Program.Foreign
import           Lib.Vulkan.Command
import           Lib.Vulkan.Descriptor
import           Lib.Vulkan.Device
import           Lib.Vulkan.Drawing
import           Lib.Vulkan.Image
import           Lib.Vulkan.Pipeline
import           Lib.Vulkan.Presentation
import           Lib.Vulkan.Shader
import           Lib.Vulkan.Shader.TH
import           Lib.Vulkan.TransformationObject
import           Lib.Vulkan.Vertex
import           Lib.Vulkan.VertexBuffer


-- | Interleaved array of vertices containing at least 3 entries.
--
--   Obviously, in real world vertices come from a separate file and not known at compile time.
--   The shader pipeline requires at least 3 unique vertices (for a triangle)
--   to render something on a screen. Setting `XN 3` here is just a handy way
--   to statically ensure the program satisfies this requirement.
--   This way, not-enough-vertices error occures at the moment of DataFrame initialization
--   instead of silently failing to render something onto a screen.
--
--   Note: in this program, `n >= 3` requirement is also forced in `Lib/Vulkan/VertexBuffer.hs`,
--         where it is not strictly necessary but allows to avoid specifying DataFrame constraints
--         in function signatures (such as, e.g. `KnownDim n`).
rectVertices :: DataFrame Vertex '[XN 3]
rectVertices = fromJust $ fromList (D @3)
  [ -- rectangle
    --              coordinate                  color        texture coordinate
    scalar $ Vertex (vec3 (-0.5) (-0.5)   0.0 ) (vec3 1 0 0) (vec2 0 0)
  , scalar $ Vertex (vec3   0.4  (-0.5)   0.0 ) (vec3 0 1 0) (vec2 1 0)
  , scalar $ Vertex (vec3   0.4    0.4    0.0 ) (vec3 0 0 1) (vec2 1 1)
  , scalar $ Vertex (vec3 (-0.5)   0.4    0.0 ) (vec3 1 1 1) (vec2 0 1)

    -- rectangle
    --              coordinate                  color        texture coordinate
  , scalar $ Vertex (vec3 (-0.5) (-0.5) (-0.5)) (vec3 1 0 0) (vec2 0 0)
  , scalar $ Vertex (vec3   0.4  (-0.5) (-0.5)) (vec3 0 1 0) (vec2 1 0)
  , scalar $ Vertex (vec3   0.4    0.4  (-0.5)) (vec3 0 0 1) (vec2 1 1)
  , scalar $ Vertex (vec3 (-0.5)   0.4  (-0.5)) (vec3 1 1 1) (vec2 0 1)

    -- triangle
  -- , scalar $ Vertex (vec2   0.9 (-0.4)) (vec3 0.2 0.5 0)
  -- , scalar $ Vertex (vec2   0.5 (-0.4)) (vec3 0 1 1)
  -- , scalar $ Vertex (vec2   0.7 (-0.8)) (vec3 1 0 0.4)
  ]

rectIndices :: DataFrame Word32 '[XN 3]
rectIndices = fromJust $ fromList (D @3)
  [ -- rectangle
    0, 1, 2, 2, 3, 0
    -- rectangle
  , 4, 5, 6, 6, 7, 4
    -- triangle
  -- , 4, 5, 6
  ]

data WhichDemo = Squares | Chalet

runVulkanProgram :: WhichDemo -> IO ()
runVulkanProgram demo = runProgram checkStatus $ do
  windowSizeChanged <- liftIO $ newIORef False
  window <- initGLFWWindow 800 600 "vulkan-triangles-GLFW" windowSizeChanged

  vulkanInstance <- createGLFWVulkanInstance "vulkan-triangles-instance"

  vulkanSurface <- createSurface vulkanInstance window
  logInfo $ "Createad surface: " ++ show vulkanSurface

  glfwWaitEventsMeanwhile $ do
    (_, pdev) <- pickPhysicalDevice vulkanInstance (Just vulkanSurface)
    logInfo $ "Selected physical device: " ++ show pdev
    msaaSamples <- getMaxUsableSampleCount pdev

    (dev, queues) <- createGraphicsDevice pdev vulkanSurface
    logInfo $ "Createad device: " ++ show dev
    logInfo $ "Createad queues: " ++ show queues

    shaderVert
      <- createVkShaderStageCI dev
            $(compileGLSL "shaders/triangle.vert")
            VK_SHADER_STAGE_VERTEX_BIT

    shaderFrag
      <- createVkShaderStageCI dev
            $(compileGLSL "shaders/triangle.frag")
            VK_SHADER_STAGE_FRAGMENT_BIT

    logInfo $ "Createad vertex shader module: " ++ show shaderVert
    logInfo $ "Createad fragment shader module: " ++ show shaderFrag

    frameIndexRef <- liftIO $ newIORef 0
    renderFinishedSems <- createFrameSemaphores dev
    imageAvailableSems <- createFrameSemaphores dev
    inFlightFences <- createFrameFences dev

    commandPool <- createCommandPool dev queues
    logInfo $ "Createad command pool: " ++ show commandPool

    -- we need this later, but don't want to realloc every swapchain recreation.
    imgIndexPtr <- mallocRes

    (vertices, indices) <- case demo of
      Squares -> return (rectVertices, rectIndices)
      Chalet -> do
        modelExist <- liftIO $ doesFileExist "models/chalet.obj"
        when (not modelExist) $
          throwVkMsg "Get models/chalet.obj and textures/chalet.jpg from the links in https://vulkan-tutorial.com/Loading_models"
        loadModel "models/chalet.obj"

    vertexBuffer <-
      createVertexBuffer pdev dev commandPool (graphicsQueue queues) vertices

    indexBuffer <-
      createIndexBuffer pdev dev commandPool (graphicsQueue queues) indices

    descriptorSetLayout <- createDescriptorSetLayout dev
    pipelineLayout <- createPipelineLayout dev descriptorSetLayout

    let texturePath = case demo of
          Squares -> "textures/texture.jpg"
          Chalet  -> "textures/chalet.jpg"
    (textureView, mipLevels) <- createTextureImageView pdev dev commandPool (graphicsQueue queues) texturePath
    textureSampler <- createTextureSampler dev mipLevels
    descriptorTextureInfo <- textureImageInfo textureView textureSampler

    depthFormat <- findDepthFormat pdev

    let beforeSwapchainCreation :: Program r ()
        beforeSwapchainCreation = do
          -- wait as long as window has width=0 and height=0
          -- commented out because this only works in the main thread:
          -- glfwWaitMinimized window

          -- If a window size change did happen, it will be respected by (re-)creating
          -- the swapchain below, no matter if it was signalled via exception or
          -- the IORef, so reset the IORef now:
          liftIO $ atomicWriteIORef windowSizeChanged False

    -- The code below re-runs when the swapchain was re-created
    loop $ do
      scsd <- querySwapchainSupport pdev vulkanSurface
      beforeSwapchainCreation
      swapInfo <- createSwapchain dev scsd queues vulkanSurface
      let swapchainLen = length (swapImgs swapInfo)

      (transObjMems, transObjBufs) <- unzip <$> createTransObjBuffers pdev dev swapchainLen
      descriptorBufferInfos <- mapM transObjBufferInfo transObjBufs

      descriptorPool <- createDescriptorPool dev swapchainLen
      descriptorSetLayouts <- newArrayRes $ replicate swapchainLen descriptorSetLayout
      descriptorSets <- createDescriptorSets dev descriptorPool swapchainLen descriptorSetLayouts

      forM_ (zip descriptorBufferInfos descriptorSets) $
        \(bufInfo, dSet) -> prepareDescriptorSet dev bufInfo descriptorTextureInfo dSet

      transObjMemories <- newArrayRes $ transObjMems

      imgViews <- mapM (\image -> createImageView dev image (swapImgFormat swapInfo) VK_IMAGE_ASPECT_COLOR_BIT 1) (swapImgs swapInfo)
      renderPass <- createRenderPass dev swapInfo depthFormat msaaSamples
      graphicsPipeline
        <- createGraphicsPipeline dev swapInfo
                                  vertIBD vertIADs
                                  [shaderVert, shaderFrag]
                                  renderPass
                                  pipelineLayout
                                  msaaSamples

      colorAttImgView <- createColorAttImgView pdev dev commandPool (graphicsQueue queues)
                          (swapImgFormat swapInfo) (swapExtent swapInfo) msaaSamples
      depthAttImgView <- createDepthAttImgView pdev dev commandPool (graphicsQueue queues)
                          (swapExtent swapInfo) msaaSamples
      framebuffers
        <- createFramebuffers dev renderPass swapInfo imgViews depthAttImgView colorAttImgView
      cmdBuffersPtr <- createCommandBuffers dev graphicsPipeline commandPool
                                        renderPass pipelineLayout swapInfo
                                        vertexBuffer
                                        (fromIntegral $ dimSize1 indices, indexBuffer)
                                        framebuffers
                                        descriptorSets

      let rdata = RenderData
            { dev
            , swapInfo
            , queues
            , imgIndexPtr
            , frameIndexRef
            , renderFinishedSems
            , imageAvailableSems
            , inFlightFences
            , cmdBuffersPtr
            , memories           = transObjMemories
            , memoryMutator      = updateTransObj dev (swapExtent swapInfo)
            }

      logInfo $ "Createad image views: " ++ show imgViews
      logInfo $ "Createad renderpass: " ++ show renderPass
      logInfo $ "Createad pipeline: " ++ show graphicsPipeline
      logInfo $ "Createad framebuffers: " ++ show framebuffers
      cmdBuffers <- peekArray swapchainLen cmdBuffersPtr
      logInfo $ "Createad command buffers: " ++ show cmdBuffers

      -- part of dumb fps counter
      frameCount <- liftIO $ newIORef @Int 0
      currentSec <- liftIO $ newIORef @Int 0

      shouldExit <- glfwMainLoop window $ do
        return () -- do some app logic

        needRecreation <- drawFrame rdata `catchError` ( \err@(VulkanException ecode _) ->
          case ecode of
            Just VK_ERROR_OUT_OF_DATE_KHR -> do
              logInfo "Have got a VK_ERROR_OUT_OF_DATE_KHR error"
              return True
            _ -> throwError err
          )

        -- part of dumb fps counter
        seconds <- getTime
        liftIO $ do
          cur <- readIORef currentSec
          if floor seconds /= cur then do
            count <- readIORef frameCount
            when (cur /= 0) $ print count
            writeIORef currentSec (floor seconds)
            writeIORef frameCount 0
          else do
            modifyIORef frameCount $ \c -> c + 1

        sizeChanged <- liftIO $ readIORef windowSizeChanged
        when sizeChanged $ logInfo "Have got a windowSizeCallback from GLFW"
        return $ if needRecreation || sizeChanged then AbortLoop else ContinueLoop
      -- after glfwMainLoop exits, we need to wait for the frame to finish before deallocating things
      runVk $ vkDeviceWaitIdle dev
      return $ if shouldExit then AbortLoop else ContinueLoop
  return ()
