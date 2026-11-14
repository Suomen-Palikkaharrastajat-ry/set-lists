module ItemOrder exposing (moveItem, targetIndex)

{-| Pure ordering helpers for the list's set rows.

A drop position is a gap between rows: gap 0 is above the first row and gap `count` is below the
last row. Moving a row forward shifts the gap back by one because the row leaves its old slot.

-}


moveItem : Int -> Int -> List a -> List a
moveItem from to values =
    case List.drop from values |> List.head of
        Nothing ->
            values

        Just item ->
            let
                remaining =
                    List.take from values ++ List.drop (from + 1) values

                safePosition =
                    clamp 0 (List.length remaining) to
            in
            List.take safePosition remaining ++ [ item ] ++ List.drop safePosition remaining


{-| The index a row dragged from `from` lands on when dropped into `gap`. Equal to `from` when the
drop leaves the order unchanged.
-}
targetIndex : Int -> Int -> Int
targetIndex from gap =
    if from < gap then
        gap - 1

    else
        gap
