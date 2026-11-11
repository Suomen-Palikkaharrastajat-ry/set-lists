module PhotoCropTest exposing (suite)

{-| BDD coverage for cover crop geometry and the stored thumbnail size.
-}

import Expect
import PhotoCrop
import Test exposing (Test, describe, test)


landscape : PhotoCrop.State
landscape =
    PhotoCrop.initialState "list-id" "data:image/webp;base64," 1200 900


suite : Test
suite =
    describe "list cover crop"
        [ test "Given a landscape photo, when the default square crop is shown, then the centered square is selected" <|
            \_ ->
                PhotoCrop.cropRegion landscape
                    |> Expect.equal { x = 150, y = 0, width = 900, height = 900 }
        , test "Given a portrait photo, when the 16:9 ratio is selected, then the full width is cropped vertically to the middle" <|
            \_ ->
                { landscape | sourceWidth = 900, sourceHeight = 1600, ratio = PhotoCrop.Landscape16x9, focusY = 0.5 }
                    |> PhotoCrop.cropRegion
                    |> Expect.equal { x = 0, y = 547, width = 900, height = 506 }
        , test "Given the 3:4 ratio, when the photo is landscape, then the crop keeps the full height" <|
            \_ ->
                { landscape | ratio = PhotoCrop.Portrait3x4 }
                    |> PhotoCrop.cropRegion
                    |> Expect.equal { x = 263, y = 0, width = 675, height = 900 }
        , test "Given zoom of two, when the crop is computed, then the region is half the size of the fitted region" <|
            \_ ->
                { landscape | zoom = 2 }
                    |> PhotoCrop.cropRegion
                    |> Expect.equal { x = 375, y = 225, width = 450, height = 450 }
        , test "Given zoom beyond the maximum, when the crop is computed, then zoom is clamped" <|
            \_ ->
                PhotoCrop.cropRegion { landscape | zoom = 10 }
                    |> Expect.equal (PhotoCrop.cropRegion { landscape | zoom = PhotoCrop.maxZoom })
        , test "Given focus at the start and end edges, when the crop is computed, then it stays inside the photo" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        { landscape | zoom = 2, focusX = 0, focusY = 0 }
                            |> PhotoCrop.cropRegion
                            |> Expect.equal { x = 0, y = 0, width = 450, height = 450 }
                    , \_ ->
                        { landscape | zoom = 2, focusX = 1, focusY = 1 }
                            |> PhotoCrop.cropRegion
                            |> Expect.equal { x = 750, y = 450, width = 450, height = 450 }
                    ]
                    ()
        , test "Given a cropped region, when its output size is computed, then the longest edge is capped at 256 pixels" <|
            \_ ->
                PhotoCrop.outputSize { x = 0, y = 0, width = 900, height = 900 }
                    |> Expect.equal { width = 256, height = 256 }
        , test "Given a wide cropped region, when its output size is computed, then the aspect ratio is kept" <|
            \_ ->
                PhotoCrop.outputSize { x = 0, y = 0, width = 1600, height = 900 }
                    |> Expect.equal { width = 256, height = 144 }
        , test "Given a small cropped region, when its output size is computed, then it is never upscaled" <|
            \_ ->
                PhotoCrop.outputSize { x = 0, y = 0, width = 90, height = 120 }
                    |> Expect.equal { width = 90, height = 120 }
        , test "Given a drag of a tenth of the frame at two times zoom, when the crop pans right, then the selected region follows to the right" <|
            \_ ->
                { landscape | zoom = 2 }
                    |> PhotoCrop.panBy 0.1 0
                    |> PhotoCrop.cropRegion
                    |> Expect.equal { x = 420, y = 225, width = 450, height = 450 }
        , test "Given a drag past the photo's left edge, when the crop pans, then the focus stays at the left edge" <|
            \_ ->
                { landscape | zoom = 2 }
                    |> PhotoCrop.panBy -1 0
                    |> PhotoCrop.cropRegion
                    |> Expect.equal { x = 0, y = 225, width = 450, height = 450 }
        , test "Given an axis that is fully visible, when the crop pans along it, then its focus does not change" <|
            \_ ->
                PhotoCrop.panBy 0 0.5 landscape
                    |> Expect.equal landscape
        , test "Given a corner of the preview, when the zoom changes, then that corner stays in place" <|
            \_ ->
                { landscape | zoom = 2 }
                    |> PhotoCrop.zoomAt 2 0 0
                    |> PhotoCrop.cropRegion
                    |> Expect.equal { x = 375, y = 225, width = 225, height = 225 }
        , test "Given the centre of the preview, when the zoom changes, then the centre stays in the middle of the crop" <|
            \_ ->
                { landscape | zoom = 2 }
                    |> PhotoCrop.zoomAt 2 0.5 0.5
                    |> PhotoCrop.cropRegion
                    |> Expect.equal { x = 488, y = 338, width = 225, height = 225 }
        , test "Given a zoom beyond the maximum, when the zoom is applied, then zoom is clamped" <|
            \_ ->
                PhotoCrop.zoomAt 100 0.5 0.5 landscape
                    |> .zoom
                    |> Expect.equal PhotoCrop.maxZoom
        ]
