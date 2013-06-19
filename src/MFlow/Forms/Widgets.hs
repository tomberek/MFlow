
{- |
Some dynamic widgets, widgets that dynamically edit content in other widgets,
widgets for templating, content management and multilanguage. And some primitives
to create other active widgets.
-}

{-# LANGUAGE UndecidableInstances,ExistentialQuantification
            , FlexibleInstances, OverlappingInstances, FlexibleContexts
            , OverloadedStrings, DeriveDataTypeable #-}




module MFlow.Forms.Widgets (
-- * User Management
userFormOrName,maybeLogout,
-- * Active widgets
wEditList,wautocomplete,wautocompleteList
, wautocompleteEdit,

-- * Editing widgets
delEdited, getEdited
,prependWidget,appendWidget,setWidget
-- * Content Management
,tField, tFieldEd, tFieldGen

-- * Multilanguage
,mFieldEd, mField

) where
import MFlow
import MFlow.Forms
import MFlow.Forms.Internals
import Data.Monoid
import qualified Data.ByteString.Lazy.Char8 as B
import Control.Monad.Trans
import Data.Typeable
import Data.List
import System.IO.Unsafe

import Control.Monad.State
import Data.TCache
import Data.TCache.Defs
import Data.TCache.Memoization
import Data.RefSerialize hiding ((<|>))
import qualified Data.Map as M
import Data.IORef
import MFlow.Cookies
import Data.Maybe
import Control.Monad.Identity


readyJQuery="ready=function(){if(!window.jQuery){return setTimeout(ready,100)}};"

jqueryScript= "http://ajax.googleapis.com/ajax/libs/jquery/1.8.3/jquery.min.js"

jqueryCSS= "http://code.jquery.com/ui/1.9.1/themes/base/jquery-ui.css"

jqueryUI= "http://code.jquery.com/ui/1.9.1/jquery-ui.js"

------- User Management ------

-- | Present a user form if not logged in. Otherwise, the user name and a logout link is presented.
-- The paremeters and the behaviour are the same as 'userWidget'.
-- Only the display is different
userFormOrName  mode wid= userWidget mode wid `wmodify` f  <** maybeLogout
  where
  f _ justu@(Just u)  =  return ([fromStr u], justu) -- !> "input"
  f felem Nothing = do
     us <- getCurrentUser -- getEnv cookieuser
     if us == anonymous
           then return (felem, Nothing)
           else return([fromStr us],  Just us)

-- | Display a logout link if the user is logged. Nothing otherwise
maybeLogout :: (MonadIO m,Functor m,FormInput v) => View v m ()
maybeLogout= do
    us <- getCurrentUser
    if us/= anonymous
      then do
          cmd <- ajax $ const $ return "window.location=='/'" --refresh
          fromStr " " ++> ((wlink () (fromStr "logout")) <![("onclick",cmd "''")]) `waction` const logout
      else noWidget

--- active widgets

data Medit view m a = Medit (M.Map B.ByteString [(String,View view m a)])
instance (Typeable view, Typeable a)
         =>Typeable (Medit view m a) where
  typeOf= \v -> mkTyConApp (mkTyCon3 "MFlow" "MFlow.Forms.Widgets" "Medit" )
                [typeOf (tview v)
                ,typeOf (ta v)]
      where
      tview :: Medit v m a -> v
      tview= undefined
      tm :: Medit v m a -> m a
      tm= undefined
      ta :: Medit v m a -> a
      ta= undefined

getEdited1 id= do
    Medit stored <-  getSessionData `onNothing` return (Medit (M.empty))
    return $ fromMaybe [] $ M.lookup id stored

-- | Return the list of edited widgets (added by the active widgets) for a given identifier
getEdited
  :: (Typeable v, Typeable a, MonadState (MFlowState view) m) =>
     B.ByteString -> m [View v m1 a]
getEdited id= do
  r <- getEdited1 id
  let (k,ws)= unzip r
  return ws

-- | Deletes the list of edited widgets for a certain identifier and with the type of the witness widget parameter
delEdited
  :: (Typeable v, Typeable a, MonadIO m,
      MonadState (MFlowState view) m)
     => B.ByteString           -- ^ identifier
     -> [View v m1 a] -> m ()  -- ^ withess
delEdited id witness=do
    (ks,ws) <- return . unzip =<< getEdited1 id
    return $ ws `asTypeOf` witness
    mapM (liftIO . flushCached) ks
    setEdited id ([] `asTypeOf` (zip (repeat "") witness))

setEdited id ws= do
    Medit stored <-  getSessionData `onNothing` return (Medit (M.empty))
    let stored'= M.insert id ws stored
    setSessionData . Medit $ stored'


addEdited id w= do
    ws <- getEdited1 id
    setEdited id (w:ws)


modifyWidget :: (MonadIO m,Executable m,Typeable a,FormInput v)
           => B.ByteString -> B.ByteString -> View v Identity a -> View v m B.ByteString
modifyWidget selector modifier  w = View $ do
     ws <- getEdited selector
     let n =  length (ws `asTypeOf` [w])
     let key= "widget"++ show selector ++  show n
     let cw = wcached key 0  w
     addEdited selector (key,cw)
     FormElm form _ <-  runView cw
     let elem=  toByteString  $ mconcat form
     return . FormElm [] . Just $   selector <> "." <> modifier <>"('" <> elem <> "');"

-- | Return the javascript to be executed on the browser to prepend a widget to the location
-- identified by the selector (the bytestring parameter), The selector must have the form of a jquery expression
-- . It stores the added widgets in the edited list, that is accessed with 'getEdited'
--
-- The resulting string can be executed in the browser. 'ajax' will return the code to
-- execute the complete ajax roundtrip. This code returned by ajax must be in an eventhabdler.
--
-- This example code will insert a widget in the div  when the element with identifier
-- /clickelem/  is clicked. when the form is sbmitted, the widget values are returned
-- and the list of edited widgets are deleted.
--
-- >    id1<- genNewId
-- >    let sel= "$('#" <>  B.pack id1 <> "')"
-- >    callAjax <- ajax . const $ prependWidget sel wn
-- >    let installevents= "$(document).ready(function(){\
-- >              \$('#clickelem').click(function(){"++callAjax "''"++"});})"
-- >
-- >    requires [JScriptFile jqueryScript [installevents] ]
-- >    ws <- getEdited sel
-- >    r <-  (div  <<< manyOf ws) <! [("id",id1)]
-- >    delEdited sel ws'
-- >    return  r

prependWidget
  :: (Typeable a, MonadIO m, Executable m, FormInput v)
  => B.ByteString           -- ^ jquery selector
  -> View v Identity a      -- ^ widget to prepend
  -> View v m B.ByteString  -- ^ string returned with the jquery string to be executed in the browser
prependWidget sel w= modifyWidget sel "prepend" w

-- | Like 'prependWidget' but append the widget instead of prepend.
appendWidget
  :: (Typeable a, MonadIO m, Executable m, FormInput v) =>
     B.ByteString -> View v Identity a -> View v m B.ByteString
appendWidget sel w= modifyWidget sel "append" w

-- | L  ike 'prependWidget' but set the entire content of the selector instead of prepending an element
setWidget
  :: (Typeable a, MonadIO m, Executable m, FormInput v) =>
     B.ByteString -> View v Identity a -> View v m B.ByteString
setWidget sel w= modifyWidget sel "html" w


-- | Inside a tag, it add and delete widgets of the same type. When the form is submitted
-- or a wlink is pressed, this widget return the list of validated widgets.
-- the event for adding a new widget is attached , as a click event to the element of the page with the identifier /wEditListAdd/
-- that the user will choose.
--
-- This example add or delete editable text boxes, with two initial boxes   with
-- /hi/, /how are you/ as values. Tt uses blaze-html:
--

-- >  r <-  ask  $   addLink
-- >              ++> br
-- >              ++> (El.div `wEditList`  getString1 $  ["hi", "how are you"]) "addid"
-- >              <++ br
-- >              <** submitButton "send"
-- >
-- >  ask $   p << (show r ++ " returned")
-- >      ++> wlink () (p << text " back to menu")
-- >  mainmenu
-- >  where
-- >  addLink = a ! At.id  "addid"
-- >              ! href "#"
-- >              $ text "add"
-- >  delBox  =  input ! type_   "checkbox"
-- >                   ! checked ""
-- >                   ! onclick "this.parentNode.parentNode.removeChild(this.parentNode)"
-- >  getString1 mx= El.div  <<< delBox ++> getString  mx <++ br

wEditList :: (Typeable a,Read a
             ,FormInput view
             ,Functor m,MonadIO m, Executable m)
          => (view ->view)     -- ^ The holder tag
          -> (Maybe String -> View view Identity a) -- ^ the contained widget, initialized  by a string
          -> [String]          -- ^ The initial list of values.
          -> String            -- ^ The id of the button or link that will create a new list element when clicked
          -> View view m  [a]
wEditList holderview w xs addId = do
    let ws=  map (w . Just) xs
        wn=  w Nothing
    id1<- genNewId
    let sel= "$('#" <>  B.pack id1 <> "')"
    callAjax <- ajax . const $ prependWidget sel wn
    let installevents= "$(document).ready(function(){\
              \$('#"++addId++"').click(function(){"++callAjax "''"++"});})"

    requires [JScriptFile jqueryScript [installevents] ]

    ws' <- getEdited sel

    r <-  (holderview  <<< (manyOf $ ws' ++ map changeMonad ws)) <! [("id",id1)]
    delEdited sel ws'
    return r

-- | Present an autocompletion list, from a procedure defined by the programmer, to a text box.
wautocomplete
  :: (Show a, MonadIO m, FormInput v)
  =>  Maybe String      -- ^ Initial value
  -> (String -> IO a)   -- ^ Autocompletion procedure: will receive a prefix and return a list of strings
  -> View v m String
wautocomplete mv autocomplete  = do
    ajaxc <- ajax $ \(u) -> do
                          r <- liftIO $ autocomplete u
                          return $ jaddtoautocomp r


    requires [JScriptFile jqueryScript [] -- [events]
             ,CSSFile jqueryCSS
             ,JScriptFile jqueryUI []]


    getString mv <!  [("type", "text")
                     ,("id", "text1")
                     ,("oninput",ajaxc "$('#text1').attr('value')" )
                     ,("autocomplete", "off")]


    where
    jaddtoautocomp us= "$('#text1').autocomplete({ source: " <> B.pack( show us) <> "  });"


-- | Produces a text box. It gives a autocompletion list to the textbox. When return
-- is pressed in the textbox, the box content is used to create a widget of a kind defined
-- by the user, which will be situated above of the textbox. When submitted, the result of this widget is the content
-- of the created widgets (the validated ones).
--
-- 'wautocompleteList' is an specialization of this widget, where
-- the widget parameter is fixed, with a checkbox that delete the eleement when unselected
-- . This fixed widget is as such (using generic 'FormElem' class tags):
--
-- > ftag "div"    <<< ftag "input" mempty
-- >                               `attrs` [("type","checkbox")
-- >                                       ,("checked","")
-- >                                       ,("onclick","this.parentNode.parentNode.removeChild(this.parentNode)")]
-- >               ++> ftag "span" (fromStr $ fromJust x )
-- >               ++> whidden( fromJust x)
wautocompleteEdit
    :: (Typeable a, MonadIO m,Functor m, Executable m
     , FormInput v)
    => String                                 -- ^ the initial text of the box
    -> (String -> IO [String])                -- ^ the autocompletion procedure: receives a prefix, return a list of options.
    -> (Maybe String  -> View v Identity a)   -- ^ the widget to add, initialized with the string entered in the box
    -> [String]                               -- ^ initial set of values
    -> View v m [a]                           -- ^ resulting widget
wautocompleteEdit phold   autocomplete  elem values= do
    id1 <- genNewId
    let sel= "$('#" <> B.pack id1 <> "')"
    ajaxc <- ajax $ \(c:u) ->
              case c of
                'f' -> prependWidget sel (elem $ Just u)
                _   -> do
                          r <- liftIO $ autocomplete u
                          return $ jaddtoautocomp r


    requires [JScriptFile jqueryScript [events ajaxc] -- [events]
             ,CSSFile jqueryCSS
             ,JScriptFile jqueryUI []]

    ws' <- getEdited sel

    r<-(ftag "div" mempty  `attrs` [("id",  id1)]
      ++> manyOf (ws' ++ (map (changeMonad . elem . Just) values)))
      <++ ftag "input" mempty
             `attrs` [("type", "text")
                     ,("id", "text1")
                     ,("placeholder", phold)
                     ,("oninput",ajaxc "'n'+$('#text1').attr('value')" )
                     ,("autocomplete", "off")]
    delEdited sel ws'
    return r
    where
    events ajaxc=
         "$(document).ready(function(){   \
         \  $('#text1').keydown(function(){ \
         \   if(event.keyCode == 13){  \
             \   var v= $('#text1').attr('value'); \
             \   if(event.preventDefault) event.preventDefault();\
             \   else if(event.returnValue) event.returnValue = false;" ++
                 ajaxc "'f'+v"++";"++
             "   $('#text1').val('');\
         \  }\
         \ });\
         \});"

    jaddtoautocomp us= "$('#text1').autocomplete({ source: " <> B.pack( show us) <> "  });"

-- | A specialization of 'selectAutocompleteEdit' which make appear each option choosen with
-- a checkbox that deletes the element when uncheched. The result, when submitted, is the list of selected elements.
wautocompleteList
  :: (Functor m, MonadIO m, Executable m, FormInput v) =>
     String -> (String -> IO [String]) -> [String] -> View v m [String]
wautocompleteList phold serverproc values=
 wautocompleteEdit phold serverproc  wrender1 values
 where
 wrender1 x= ftag "div"    <<< ftag "input" mempty
                                `attrs` [("type","checkbox")
                                        ,("checked","")
                                        ,("onclick","this.parentNode.parentNode.removeChild(this.parentNode)")]
                           ++> ftag "span" (fromStr $ fromJust x )
                           ++> whidden( fromJust x)

------- Templating and localization ---------

writetField    k s=  atomically $ writetFieldSTM k s

writetFieldSTM k s=  do
             phold <- readDBRef tFields `onNothing` return (M.fromList [])
             let r= M.insert k  (toByteString s) phold
             writeDBRef tFields   r

readtField text k= atomically $ do
       hs<- readDBRef tFields `onNothing` return (M.fromList [])
       let mp=  M.lookup k hs
       case mp of
         Just c  -> return   $ fromStrNoEncode $ B.unpack c
         Nothing -> writetFieldSTM k  text >> return  text

type TFields  = M.Map String B.ByteString
instance Indexable TFields where
    key _= "texts"
    defPath _= "texts/"

tFields :: DBRef TFields
tFields =  getDBRef "texts"

type Key= String

-- | A widget that display the content of an  html, But if logged as administrator,
-- it permits to edit it in place. So the editor could see the final appearance
-- of what he write in the page.
--
-- When the administrator double click in the paragraph, the content is saved and
-- identified by the key. Then, from now on, all the users will see the saved
-- content instead of the code content.
--
-- The content is saved in a file by default (/texts/ in this versions), but there is
-- a configurable version (`tFieldGen`). The content of the element and the formatting
-- is cached in memory, so the display is, theoretically, very fast.
--
-- THis is an example of how to use the content management primitives (in demos.blaze.hs):
--
-- > textEdit= do
-- >   setHeader $ \t -> html << body << t
-- >
-- >   let first=  p << i <<
-- >                  (El.span << text "this is a page with"
-- >                  <> b << text " two " <> El.span << text "paragraphs")
-- >
-- >       second= p << i << text "This is the original text of the second paragraph"
-- >
-- >       pageEditable =  (tFieldEd "first"  first)
-- >                   **> (tFieldEd "second" second)
-- >
-- >   ask $   first
-- >       ++> second
-- >       ++> wlink () (p << text "click here to edit it")
-- >
-- >   ask $ p << text "Please login with admin/admin to edit it"
-- >           ++> userWidget (Just "admin") userLogin
-- >
-- >   ask $   p << text "now you can click the field and edit them"
-- >       ++> p << b << text "to save the edited field, double click on it"
-- >       ++> pageEditable
-- >       **> wlink () (p << text "click here to see it as a normal user")
-- >
-- >   logout
-- >
-- >   ask $   p << text "the user sees the edited content. He can not edit"
-- >       ++> pageEditable
-- >       **> wlink () (p << text "click to continue")
-- >
-- >   ask $   p << text "When text are fixed,the edit facility and the original texts can be removed. The content is indexed by the field key"
-- >       ++> tField "first"
-- >       **> tField "second"
-- >       **> p << text "End of edit field demo" ++> wlink () (p << text "click here to go to menu")
tFieldEd
  :: (Functor m,  MonadIO m, Executable m,
      FormInput v) =>
      Key -> v -> View v m ()
tFieldEd  k text=
   tFieldGen k  (readtField text) writetField


-- | Like 'tFieldEd' with user-configurable storage.
tFieldGen :: (MonadIO m,Functor m, Executable m
        ,FormInput v)
        => Key
        -> (Key -> IO  v)  -- ^ the read procedure, user defined
        -> (Key ->v  -> IO())   -- ^ the write procedure, user defiend
        -> View v m ()
tFieldGen  k  getcontent create =   wfreeze k 0 $ do
    content <-  liftIO $ getcontent  k
    admin   <- getAdminName
    ajaxjs   <- ajax  $ \str -> do
              let (k,s)= break (==',')    str !> str
              liftIO  . create  k  $ fromStrNoEncode (tail s)
              liftIO $ flushCached k
              return "alert('saved')"
    attribs <- do
            name <- genNewId
            -- Need to check the user in the browser because the widget is wfreeze'd
            let ifUserAdmin= "if(document.cookie.search('"++cookieuser++"="++admin++"') != -1)"
                nikeditor= "var myNicEditor = new nicEditor();"
                callback=ifUserAdmin ++
                  "bkLib.onDomLoaded(function() {\
                     \    myNicEditor.addInstance('"++name++"');\
                     \});"
                param= ("'"++k  ++ "'+','+ document.getElementById('"++name++"').innerHTML")

            requires  [JScriptFile "http://js.nicedit.com/nicEdit-latest.js" [nikeditor, callback]]

            return [("id", name),("ondblclick",  ifUserAdmin ++ ajaxjs param)]

    wraw $  (ftag "span" content `attrs` attribs)

-- | Read the field value and present it without edition.
tField :: (MonadIO m,Functor m, Executable m
       ,  FormInput v)
       => Key
       -> View v m ()
tField  k    =  wfreeze k 0 $ do
    content <-  liftIO $ readtField (fromStrNoEncode "not found")  k
    wraw content

-- | A multilanguage version of tFieldEd. For a field with @key@ it add a suffix with the
-- two characters of the language used.
mFieldEd k content= do
  lang <- getLang
  tFieldEd (k ++ ('-':lang)) content

-- | A multilanguage version of tField
mField k= do
  lang <- getLang
  tField $ k ++ ('-':lang)

-- | present a calendar to choose a date
datePicker :: (Monad m, FormInput v) => Maybe String -> View v m (Int,Int,Int)
datePicker jd= do
    id <- genNewId
    let setit= "$(function() {\
                   \$( '"++id++"' ).datepicker();\
                \});"

    requires
      [CSSFile      jqueryCSS
      ,JScriptFile  jqueryScript []
      ,JScriptFile  jqueryUI [setit]]

    s <- getString jd <! [("id",id)]
    let (month,r) = span (/='/')  s
    let (day,r2)= span(/='/') $ tail r
    return (read day,read month, read $ tail r2)
