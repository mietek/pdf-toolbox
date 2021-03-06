{-# LANGUAGE OverloadedStrings #-}

module Main
(
  main
)
where

import qualified Data.Traversable as Traversable
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Text as Text
import Data.IORef
import Control.Monad
import Control.Monad.IO.Class
import Control.Concurrent
import System.IO
import System.Directory
import System.FilePath
import System.Random (randomIO)
import System.Process
import System.Exit
import Graphics.UI.Gtk hiding (Rectangle, FontMap, rectangle)
import Graphics.Rendering.Cairo hiding (transform, Glyph)

import Pdf.Toolbox.Document
import Pdf.Toolbox.Document.Encryption
import Pdf.Toolbox.Content

data ViewerState = ViewerState {
  viewerPage :: Page,
  viewerPageNum :: Int,
  viewerRenderIM :: Bool,
  viewerRenderText :: Bool,
  viewerRenderGlyphs :: Bool
  }

main :: IO ()
main = do
  [file] <- initGUI

  mvar <- newEmptyMVar
  withBinaryFile file ReadMode $ \h -> do
  _ <- forkIO $ pdfThread h mvar

  (rootNode, totalPages, title) <- pdfSync mvar $ do
    encrypted <- isEncrypted
    when encrypted $ do
      liftIO $ putStrLn "WARNING: Document is encrypted, it is not fully supported yet"
      ok <- setUserPassword defaultUserPassword
      unless ok $ error "Need user password"
    pdf <- document
    title <- do
      info <- documentInfo pdf
      case info of
        Nothing -> return Nothing
        Just i -> infoTitle i
    root <- documentCatalog pdf >>= catalogPageNode
    total <- pageNodeNKids root
    return (root, total, title)

  firstPage <- pdfSync mvar $ do
    pageNodePageByNum rootNode 0

  viewerState <- newIORef ViewerState {
    viewerPage = firstPage,
    viewerPageNum = 0,
    viewerRenderIM = False,
    viewerRenderText = True,
    viewerRenderGlyphs = False
    }

  let winTitle = maybe "Untitled" (\(Str s) -> BS8.unpack s) title

  window <- windowNew
  set window [
    windowDefaultWidth := 300,
    windowDefaultHeight := 300,
    windowTitle := winTitle
    ]
  _ <- on window deleteEvent $ liftIO mainQuit >> return True

  vbox <- vBoxNew False 10
  containerAdd window vbox

  hbuttonBox <- hButtonBoxNew
  boxPackStart vbox hbuttonBox PackNatural 0

  prevButton <- buttonNewWithLabel ("Prev" :: String)
  boxPackStart hbuttonBox prevButton PackNatural 0

  nextButton <- buttonNewWithLabel ("Next" :: String)
  boxPackStart hbuttonBox nextButton PackNatural 0

  renderPdfToggle <- checkButtonNewWithLabel ("Render via ImageMagick" :: String)
  set renderPdfToggle [
    toggleButtonActive := False
    ]
  boxPackStart hbuttonBox renderPdfToggle PackNatural 0

  renderTextToggle <- checkButtonNewWithLabel ("Render extracted text" :: String)
  set renderTextToggle [
    toggleButtonActive := True
    ]
  boxPackStart hbuttonBox renderTextToggle PackNatural 0

  renderGlyphsToggle <- checkButtonNewWithLabel ("Render glyphs" :: String)
  set renderGlyphsToggle [
    toggleButtonActive := False
    ]
  boxPackStart hbuttonBox renderGlyphsToggle PackNatural 0

  frame <- frameNew
  boxPackStart vbox frame PackGrow 0

  canvas <- drawingAreaNew
  containerAdd frame canvas

  _ <- on renderPdfToggle toggled $ do
    st <- get renderPdfToggle toggleButtonActive
    modifyIORef viewerState $ \s -> s {
      viewerRenderIM = st
      }
    widgetQueueDraw canvas

  _ <- on renderTextToggle toggled $ do
    st <- get renderTextToggle toggleButtonActive
    modifyIORef viewerState $ \s -> s {
      viewerRenderText = st
      }
    widgetQueueDraw canvas

  _ <- on renderGlyphsToggle toggled $ do
    st <- get renderGlyphsToggle toggleButtonActive
    modifyIORef viewerState $ \s -> s {
      viewerRenderGlyphs = st
      }
    widgetQueueDraw canvas

  _ <- on prevButton buttonActivated $ do
    num <- viewerPageNum <$> readIORef viewerState
    when (num > 0) $ do
      p <- pdfSync mvar $ pageNodePageByNum rootNode (num - 1)
      modifyIORef viewerState $ \s -> s {
        viewerPage = p,
        viewerPageNum = num - 1
        }
      widgetQueueDraw canvas

  _ <- on nextButton buttonActivated $ do
    num <- viewerPageNum <$> readIORef viewerState
    when (num < totalPages - 1) $ do
      p <- pdfSync mvar $ pageNodePageByNum rootNode (num + 1)
      modifyIORef viewerState $ \s -> s {
        viewerPage = p,
        viewerPageNum = num + 1
        }
      widgetQueueDraw canvas

  widgetShowAll window
  draw <- widgetGetDrawWindow canvas
  _ <- on canvas exposeEvent $ do
    liftIO $ renderWithDrawable draw $ onDraw file mvar viewerState
    return True

  mainGUI

onDraw :: FilePath -> MVar (Pdf IO Bool) -> IORef ViewerState -> Render ()
onDraw file mvar viewerState = do
  st <- liftIO $ readIORef viewerState
  let pg = viewerPage st
      num = viewerPageNum st

  when (viewerRenderIM st) $ do
    randomNum <- liftIO $ randomIO :: Render Int
    tmpDir <- liftIO $ getTemporaryDirectory
    let tmpFile = tmpDir </> ("pdf-toolbox-viewer-" ++ show randomNum ++ ".png")
    (_, _, _, procHandle) <- liftIO $ createProcess $ proc "convert" [file ++ "[" ++ show num ++ "]", tmpFile]
    hasPng <- (== ExitSuccess) <$> liftIO (waitForProcess procHandle)
    if hasPng
      then do
        surface <- liftIO $ imageSurfaceCreateFromPNG tmpFile
        setSourceSurface surface 0 0
        paint
        surfaceFinish surface
        liftIO $ removeFile tmpFile
      else liftIO $ putStrLn "Can't render pdf via ImageMagick. Please check that you have \"convert\" in PATH"

  setSourceRGB 1 1 1
  setLineWidth 1

  Rectangle llx lly urx ury <- liftIO $ pdfSync mvar $ pageMediaBox pg

  chan <- liftIO $ startRender mvar pg

  moveTo llx lly
  lineTo llx ury
  lineTo urx ury
  lineTo urx lly
  lineTo llx lly
  closePath
  stroke

  let loop = do
        cmd <- liftIO $ readChan chan
        case cmd of
          Nothing -> return ()
          Just glyph -> do
            let Vector x1 y1 = glyphTopLeft glyph
                Vector x2 y2 = glyphBottomRight glyph
            when (viewerRenderText st) $ do
              setSourceRGB 0 0 0
              case glyphText glyph of
                Nothing -> return ()
                Just txt -> do
                  moveTo x1 (ury - y1)
                  showText $ Text.unpack txt
                  stroke
            when (viewerRenderGlyphs st) $ do
              setSourceRGBA 0 0 0 0.2
              rectangle x1 (ury - y1) (x2 - x1) (y2 - y1)
              fill
            loop
  loop

pageGlyphDecoder :: (MonadPdf m, MonadIO m) => Page -> PdfE m GlyphDecoder
pageGlyphDecoder page = do
  fontDicts <- Map.fromList <$> pageFontDicts page
  decoders <- Traversable.forM fontDicts $ \fontDict -> do
    fontInfo <- fontDictLoadInfo fontDict
    return $ fontInfoDecodeGlyphs fontInfo
  return $ \fontName str ->
    case Map.lookup fontName decoders of
      Nothing -> []
      Just decode -> decode str

startRender :: MVar (Pdf IO Bool) -> Page -> IO (Chan (Maybe Glyph))
startRender mvar page = do
  chan <- newChan
  putMVar mvar $ do
    glyphDecoder <- pageGlyphDecoder page

    contents <- pageContents page
    streams <- forM contents $ \ref -> do
      s@(Stream dict _) <- lookupObject ref >>= toStream
      len <- lookupDict "Length" dict >>= deref >>= fromObject >>= intValue
      return (s, ref, len)
    ris <- getRIS
    decryptor <- do
      dec <- getDecryptor
      case dec of
        Nothing -> return $ \_ is -> return is
        Just d -> return $ \ref is -> d ref DecryptStream is
    is <- parseContentStream ris knownFilters decryptor streams

    let loop p = do
          next <- readNextOperator is
          case next of
            Nothing -> do
              forM_ (prGlyphs p) $ \glyphs ->
                forM_ glyphs $ \glyph ->
                  liftIO $ writeChan chan (Just glyph)
              --liftIO $ print $ prGlyphs p
            Just (Op_quote, args) -> error $ "Op_quote (please report): " ++ show args
            Just op -> processOp op p >>= loop
    loop $ mkProcessor {
      prGlyphDecoder = glyphDecoder
      }
    liftIO $ writeChan chan Nothing
    return False
  return chan

pdfThread :: Handle -> MVar (Pdf IO Bool) -> IO ()
pdfThread handle mvar = do
  res <- runPdfWithHandle handle knownFilters loop
  print res
  where
  loop = do
    action <- liftIO $ takeMVar mvar
    exit <- action
    unless exit loop

pdfSync :: MVar (Pdf IO Bool) -> Pdf IO a -> IO a
pdfSync mvar action = do
  mvar' <- newEmptyMVar
  putMVar mvar $ do
    res <- (Right <$> action) `catchT` (return . Left)
    liftIO $ putMVar mvar' res
    return False
  res <- takeMVar mvar'
  case res of
    Left e -> print e >> fail (show e)
    Right r -> return r
