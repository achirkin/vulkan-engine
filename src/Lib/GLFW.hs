{-# LANGUAGE Strict #-}
module Lib.GLFW
    ( createGLFWVulkanInstance
    , initGLFWWindow
    , glfwMainLoop
    , glfwWaitMinimized
    , glfwWaitEventsMeanwhile
    ) where

import           Control.Monad       (unless, when, forever)
import           Graphics.UI.GLFW    (ClientAPI (..), WindowHint (..))
import qualified Graphics.UI.GLFW    as GLFW
import           Graphics.Vulkan

import           Lib.MonadIO.IORef
import           Lib.Program
import           Lib.Vulkan.Instance


initGLFWWindow :: Int -- ^ Window width
               -> Int -- ^ Window height
               -> String -- ^ Window name
               -> IORef Bool -- ^ Window size change signalling
               -> Program r GLFW.Window
initGLFWWindow w h n windowSizeChanged = do

    -- even if something bad happens, we need to terminate GLFW
    allocResource
      (\() -> liftIO GLFW.terminate >> logInfo "Terminated GLFW.")
      ( liftIO GLFW.init >>= flip unless
          (throwVkMsg "Failed to initialize GLFW.")
      )

    liftIO GLFW.getVersionString >>= mapM_ (logInfo . ("GLFW version: " ++))

    liftIO GLFW.vulkanSupported >>= flip unless
      (throwVkMsg "GLFW reports that vulkan is not supported!")

    liftIO . GLFW.windowHint $ WindowHint'ClientAPI ClientAPI'NoAPI
    liftIO . GLFW.windowHint $ WindowHint'Resizable True

    allocResource
      ( \window -> do
          liftIO (GLFW.destroyWindow window)
          logDebug "Closed GLFW window."
      ) $ do
      mw <- liftIO $ GLFW.createWindow w h n Nothing Nothing
      case mw of
        Nothing -> throwVkMsg "Failed to initialize GLFW window."
        Just window  -> do
          logDebug "Initialized GLFW window."
          liftIO $ GLFW.setWindowSizeCallback window $
            Just (\_ _ _ -> atomicWriteIORef windowSizeChanged True)
          return window


-- | Repeats until WindowShouldClose flag is set. Returns true if program should exit.
glfwMainLoop :: GLFW.Window -> Program' (LoopControl ()) -> Program r Bool
glfwMainLoop w action = go
  where
    go = do
      should <- liftIO $ GLFW.windowShouldClose w
      if not should then do
        status <- locally action
        if status == ContinueLoop then go else return False
      else return True


-- | Runs GLFW event handling in the main thread continuously.
--
--   Waits repeatedly with 1 second timeout to allow exceptions to be handled
--   without events happening. If waiting without timeout, the waitEvents
--   function would need to be marked interruptible in the GLFW binding.
glfwWaitEventsMeanwhile :: Program' () -> Program r ()
glfwWaitEventsMeanwhile action = occupyThreadAndFork (liftIO $ forever $ GLFW.waitEventsTimeout 1.0) action


glfwWaitMinimized :: GLFW.Window -> Program r ()
glfwWaitMinimized win = liftIO go where
  go = do
    (x,y) <- GLFW.getFramebufferSize win
    GLFW.waitEvents
    when (x == 0 && y == 0) go

createGLFWVulkanInstance :: String -> Program r VkInstance
createGLFWVulkanInstance progName = do
    -- get required extension names from GLFW
    glfwReqExts <- liftIO GLFW.getRequiredInstanceExtensions
    createVulkanInstance
      progName
      "My perfect Haskell engine"
      glfwReqExts
      []
