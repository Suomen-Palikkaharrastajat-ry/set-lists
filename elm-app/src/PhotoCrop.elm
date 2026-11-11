module PhotoCrop exposing
    ( CoverRatio(..)
    , CropRegion
    , State
    , allRatios
    , coverMaxDimension
    , cropRegion
    , initialState
    , maxZoom
    , minZoom
    , outputSize
    , panBy
    , ratioId
    , ratioLabel
    , ratioValue
    , zoomAt
    )

{-| Pure crop geometry for list cover photos.

The same integer region drives the overlay shown to the user and the canvas crop sent to the
browser, so the preview and the uploaded image cannot drift apart.

i18n-exempt: The application is Finnish-only, and these are local Finnish selector labels.

-}


coverMaxDimension : Int
coverMaxDimension =
    256


minZoom : Float
minZoom =
    1


maxZoom : Float
maxZoom =
    4


type CoverRatio
    = Square
    | Landscape4x3
    | Landscape16x9
    | Portrait3x4


allRatios : List CoverRatio
allRatios =
    [ Square, Landscape4x3, Landscape16x9, Portrait3x4 ]


ratioValue : CoverRatio -> Float
ratioValue ratio =
    case ratio of
        Square ->
            1

        Landscape4x3 ->
            4 / 3

        Landscape16x9 ->
            16 / 9

        Portrait3x4 ->
            3 / 4


ratioLabel : CoverRatio -> String
ratioLabel ratio =
    case ratio of
        Square ->
            "1:1 neliö (oletus)"

        Landscape4x3 ->
            "4:3 vaaka"

        Landscape16x9 ->
            "16:9 laajakuva"

        Portrait3x4 ->
            "3:4 pysty"


ratioId : CoverRatio -> String
ratioId ratio =
    case ratio of
        Square ->
            "square"

        Landscape4x3 ->
            "landscape-4-3"

        Landscape16x9 ->
            "landscape-16-9"

        Portrait3x4 ->
            "portrait-3-4"


type alias CropRegion =
    { x : Int
    , y : Int
    , width : Int
    , height : Int
    }


type alias State =
    { listId : String
    , previewUrl : String
    , sourceWidth : Int
    , sourceHeight : Int
    , ratio : CoverRatio
    , zoom : Float
    , focusX : Float
    , focusY : Float
    }


initialState : String -> String -> Int -> Int -> State
initialState listId previewUrl sourceWidth sourceHeight =
    { listId = listId
    , previewUrl = previewUrl
    , sourceWidth = sourceWidth
    , sourceHeight = sourceHeight
    , ratio = Square
    , zoom = minZoom
    , focusX = 0.5
    , focusY = 0.5
    }


{-| The largest region with the selected ratio, reduced by the zoom factor and positioned by the
focus fractions (0 = start edge, 1 = end edge). Values are clamped so the region always fits.
-}
cropRegion : State -> CropRegion
cropRegion state =
    let
        zoom =
            clampFloat minZoom maxZoom state.zoom

        ( baseWidth, baseHeight ) =
            fittedSize state

        width =
            clampInt 1 state.sourceWidth (round (baseWidth / zoom))

        height =
            clampInt 1 state.sourceHeight (round (baseHeight / zoom))

        x =
            round (clampFloat 0 1 state.focusX * toFloat (state.sourceWidth - width))

        y =
            round (clampFloat 0 1 state.focusY * toFloat (state.sourceHeight - height))
    in
    { x = x, y = y, width = width, height = height }


{-| Moves the crop selection with a pointer distance given as fractions of the preview frame. The
selection follows the pointer, so dragging right increases the horizontal focus.
-}
panBy : Float -> Float -> State -> State
panBy dx dy state =
    let
        visible =
            visibleFraction state
    in
    { state
        | focusX = panFocus visible.width dx state.focusX
        , focusY = panFocus visible.height dy state.focusY
    }


{-| Multiplies the zoom by a factor while keeping the point at the given preview-frame fractions
under the same place on screen.
-}
zoomAt : Float -> Float -> Float -> State -> State
zoomAt factor pointerX pointerY state =
    let
        zoom =
            clampFloat minZoom maxZoom (state.zoom * factor)

        before =
            visibleFraction state

        after =
            visibleFraction { state | zoom = zoom }
    in
    { state
        | zoom = zoom
        , focusX = anchoredFocus before.width after.width (clampFloat 0 1 pointerX) state.focusX
        , focusY = anchoredFocus before.height after.height (clampFloat 0 1 pointerY) state.focusY
    }


fittedSize : State -> ( Float, Float )
fittedSize state =
    let
        sourceWidth =
            toFloat state.sourceWidth

        sourceHeight =
            toFloat state.sourceHeight

        ratio =
            ratioValue state.ratio
    in
    if sourceWidth / sourceHeight > ratio then
        ( sourceHeight * ratio, sourceHeight )

    else
        ( sourceWidth, sourceWidth / ratio )


{-| Fraction of the source size that the crop covers on each axis, as shown in the preview.
-}
visibleFraction : State -> { width : Float, height : Float }
visibleFraction state =
    let
        zoom =
            clampFloat minZoom maxZoom state.zoom

        ( baseWidth, baseHeight ) =
            fittedSize state
    in
    { width = min 1 (baseWidth / (zoom * toFloat state.sourceWidth))
    , height = min 1 (baseHeight / (zoom * toFloat state.sourceHeight))
    }


panFocus : Float -> Float -> Float -> Float
panFocus visible delta focus =
    if visible >= 1 then
        focus

    else
        clampFloat 0 1 (focus + delta * visible / (1 - visible))


anchoredFocus : Float -> Float -> Float -> Float -> Float
anchoredFocus beforeVisible afterVisible pointer focus =
    if afterVisible >= 1 then
        focus

    else
        let
            pointed =
                focus * (1 - beforeVisible) + pointer * beforeVisible

            start =
                pointed - pointer * afterVisible
        in
        clampFloat 0 1 (start / (1 - afterVisible))


{-| Pixel size of the stored cover, matching the browser's thumbnail sizing: never upscaled and
capped at `coverMaxDimension` on the longest edge.
-}
outputSize : CropRegion -> { width : Int, height : Int }
outputSize region =
    let
        scale =
            min 1 (min (toFloat coverMaxDimension / toFloat region.width) (toFloat coverMaxDimension / toFloat region.height))
    in
    { width = max 1 (round (toFloat region.width * scale))
    , height = max 1 (round (toFloat region.height * scale))
    }


clampFloat : Float -> Float -> Float -> Float
clampFloat low high value =
    max low (min high value)


clampInt : Int -> Int -> Int -> Int
clampInt low high value =
    max low (min high value)
