module ItemOrderTest exposing (suite)

{-| BDD coverage for moving set rows by drag and drop.
-}

import Expect
import ItemOrder
import Test exposing (Test, describe, test)


rows : List String
rows =
    [ "a", "b", "c", "d" ]


suite : Test
suite =
    describe "set row drag order"
        [ test "Given a row dropped below a later row, when the order is applied, then it lands after that row" <|
            \_ ->
                ItemOrder.moveItem 0 (ItemOrder.targetIndex 0 3) rows
                    |> Expect.equal [ "b", "c", "a", "d" ]
        , test "Given a row dropped above an earlier row, when the order is applied, then it lands before that row" <|
            \_ ->
                ItemOrder.moveItem 3 (ItemOrder.targetIndex 3 1) rows
                    |> Expect.equal [ "a", "d", "b", "c" ]
        , test "Given a row dropped into the gaps touching its own position, when the target is computed, then the order is unchanged" <|
            \_ ->
                Expect.all
                    [ \_ -> ItemOrder.targetIndex 1 1 |> Expect.equal 1
                    , \_ -> ItemOrder.targetIndex 1 2 |> Expect.equal 1
                    ]
                    ()
        , test "Given the first and last rows dropped at the outer gaps, when the target is computed, then they stay at their ends" <|
            \_ ->
                Expect.all
                    [ \_ -> ItemOrder.targetIndex 0 0 |> Expect.equal 0
                    , \_ -> ItemOrder.targetIndex 3 4 |> Expect.equal 3
                    ]
                    ()
        , test "Given a row dropped at the end gap, when the order is applied, then it becomes the last row" <|
            \_ ->
                ItemOrder.moveItem 1 (ItemOrder.targetIndex 1 4) rows
                    |> Expect.equal [ "a", "c", "d", "b" ]
        ]
