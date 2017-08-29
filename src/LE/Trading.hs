module LE.Trading where

import Protolude

import Control.Monad.Loops
import Control.Concurrent.STM

import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Sequence as Q
import Data.Tagged

import LE.Types
import LE.Map

type ConsistencyCheck = Exchange -> STM Bool

allCurrencies :: S.Set Currency
allCurrencies = S.fromList [
  "USD",
  "BTC",
  "ETH"
  ]

cancelBid :: Bid -> OrderBook -> OrderBook
cancelBid bid book@OrderBook{..} =
  let k = price $ unTagged bid
      (_, deletedBids) = deleteFindEq k bid _book_bids
  in book { _book_bids = deletedBids }

cancelAsk :: Ask -> OrderBook -> OrderBook
cancelAsk ask book@OrderBook{..} =
  let k = price $ unTagged ask
      (_, deletedAsks) = deleteFindEq k ask _book_asks
  in book { _book_asks = deletedAsks }

lowestAsk :: OrderBook -> (Maybe Ask, OrderBook)
lowestAsk book@OrderBook{..} =
  let (mAsk, deletedAsks) = deleteFindMin _book_asks
      newBook = book { _book_asks = deletedAsks }
  in (mAsk, newBook)

highestBid :: OrderBook -> (Maybe Bid, OrderBook)
highestBid book@OrderBook{..} =
  let (mBid, deletedBids) = deleteFindMax _book_bids
      newBook = book { _book_bids = deletedBids }
  in (mBid, newBook)
     
fillBid :: Bid -> OrderBook -> ([Trade], OrderBook)
fillBid bid book = case matchBid bid book of
  (Nothing, trades, book) ->
    (trades, book)
  (Just bidRemainder, trades, book) ->
    (trades, unsafe_addBid bidRemainder book)

fillAsk :: Ask -> OrderBook -> ([Trade], OrderBook)
fillAsk ask book = case matchAsk ask book of
  (Nothing, trades, book) ->
    (trades, book)
  (Just askRemainder, trades, book) ->
    (trades, unsafe_addAsk askRemainder book)

tryFillMBid :: MBid -> Balances -> OrderBook -> (Maybe MBid, [Trade], OrderBook)
tryFillMBid mbid bals book@OrderBook{..} =
  case M.lookup _book_toCurrency bals of
    Nothing -> (Nothing, [], book)
    Just toBalance ->
      -- A Market order is a non-persistable limit order with the user bidding his entire balance.
      let (Tagged MarketOrder{..}) = mbid
          bid = Tagged $ LimitOrder {
            _lorder_user = _morder_user,
            _lorder_fromAmount = _morder_amount,
            _lorder_toAmount = toBalance
            }
      in case matchBid bid book of
        (Nothing, trades, book) ->
          (Nothing, trades, book)
        (Just bid, trades, book) ->
          (Just $ bidToMbid bid, trades, book)

mbidToBid :: OrderBook -> MBid -> Bid
mbidToBid = undefined
             
bidToMbid :: Bid -> MBid
bidToMbid (Tagged LimitOrder{..}) = undefined
             
matchBid :: Bid -> OrderBook -> (Maybe Bid, [Trade], OrderBook)
matchBid bid book =
  let pair = _book_pair book
      loop :: (Bid, [Trade], OrderBook) -> (Maybe Bid, [Trade], OrderBook)
      loop x@(bid, trades, book) =
        case lowestAsk book of
          -- Case 1: The order book has no asks
          (Nothing, _) -> (Just bid, [], book)
          (Just lowestAsk, deletedBook) ->
            case mergeBid pair bid lowestAsk of
              -- Case 2: The bid was unable to be matched
              (Just bid, Just _, Nothing) -> (Just bid, trades, book)
              -- Case 3: The bid was partially matched; repeat the loop
              (Just bidRemainder, Nothing, Just trade) ->
                loop (bidRemainder, trade:trades, deletedBook)
              -- Case 4: The ask was partially matched; terminate the loop.
              (Nothing, Just askRemainder, Just trade) ->
                (Nothing, trade:trades, unsafe_addAsk askRemainder deletedBook)
              -- Case 5: The bid and ask exactly canceled each other out
              (Nothing, Nothing, Just trade) ->
                (Nothing, trade:trades, deletedBook)
              -- Case 6: Impossible cases
              x -> panic $ "fillBid: Unexpected case: " <> show x
  in loop (bid, [], book)

matchAsk :: Ask -> OrderBook -> (Maybe Ask, [Trade], OrderBook)
matchAsk ask book =
  let pair = _book_pair book
      loop :: (Ask, [Trade], OrderBook) -> (Maybe Ask, [Trade], OrderBook)
      loop x@(ask, trades, book) =
        case highestBid book of
          -- Case 1: The order book has no bids
          (Nothing, _) -> (Just ask, [], book)
          (Just highestBid, deletedBook) ->
            case mergeBid pair highestBid ask of
              -- Case 2: The ask was unable to be matched
              (Just _, Just _, Nothing) -> (Just ask, trades, book)
              -- Case 3: The ask was partially matched; repeat the loop
              (Nothing, Just askRemainder, Just trade) ->
                loop (askRemainder, trade:trades, deletedBook)
              -- Case 4: The bid was partially matched; terminate the loop.
              (Just bidRemainder, Nothing, Just trade) ->
                (Nothing, trade:trades, unsafe_addBid bidRemainder deletedBook)
              -- Case 5: The bid and ask exactly canceled each other out
              (Nothing, Nothing, Just trade) -> (Nothing, trade:trades, deletedBook)
              -- Case 6: Impossible cases
              x -> panic $ "fillBid: Unexpected case: " <> show x
  in loop (ask, [], book)

mergeBid :: CurrencyPair -> Bid -> Ask -> (Maybe Bid, Maybe Ask, Maybe Trade)
mergeBid (fromCurrency, toCurrency) bid ask =
  let bidOrder = unTagged bid
      askOrder = unTagged ask
      n1 = _lorder_fromAmount bidOrder
      d1 = _lorder_toAmount bidOrder
      n2 = negate $ _lorder_fromAmount askOrder
      d2 = _lorder_toAmount askOrder
      buyer = _lorder_user bidOrder
      seller = _lorder_user askOrder
      fi = fromIntegral
      -- If seller rounds down, price would be below his limit.
      sellerPrice = ceiling (fi n2 / fi d2)
      -- If buyer rounds up, price would be above his limit.
      buyerPrice = floor (fi n1 / fi d1)

      unitPrice = buyerPrice
      numUnits = min n1 n2
      toAmount = unitPrice * numUnits
      fromTransfer = DoubleEntry {
        _de_fromAccount = seller,
        _de_toAccount   = buyer,
        _de_amount      = numUnits,
        _de_currency    = fromCurrency
        }
      toTransfer = DoubleEntry {
        _de_fromAccount = buyer,
        _de_toAccount   = seller,
        _de_amount      = toAmount,
        _de_currency    = toCurrency
        }
      trade = Trade fromTransfer toTransfer
      (mNewBid, mNewAsk) = case n1 `compare` n2 of
        -- Case 1: Buyer is done; seller still has inventory
        LT -> let newAsk = Tagged $ LimitOrder {
                    _lorder_user       = seller,
                    _lorder_fromAmount = n2 - numUnits,
                    _lorder_toAmount   = sellerPrice
                    }
              in (Nothing, Just newAsk)
        -- Case 2: Seller is out; buyer needs more
        GT -> let newBid = Tagged $ LimitOrder {
                    _lorder_user       = buyer,
                    _lorder_fromAmount = n1 - numUnits,
                    _lorder_toAmount   = buyerPrice
                    }
              in (Just newBid, Nothing)
        -- Case 3: Buyer and seller exactly traded
        EQ -> (Nothing, Nothing)
  in if buyerPrice >= sellerPrice
     -- Bid has crossed the ask, so we can generate a trade.
     then (mNewBid, mNewAsk, Just trade)
     -- Bid is less than ask, so they can't be merged.
     else (Just bid, Just ask, Nothing)

unsafe_addBid :: Bid -> OrderBook -> OrderBook
unsafe_addBid bid book@OrderBook{..} = undefined
  -- book { _book_bids = _book_bids Q.|> bid }

unsafe_addAsk :: Ask -> OrderBook -> OrderBook
unsafe_addAsk = undefined
-- unsafe_addAsk ask book@OrderBOok{..} =
--   book { _book_asks = _books_asks |> ask }

isBid :: LimitOrder -> Bool
isBid order =  _lorder_fromAmount order > 0

-- findTrade :: OrderBook -> Maybe Trade
-- findTrade book =
--   let orders1 = _book_orders book
--       ((fromAmt, fromOrders), orders2) = deleteFindMin orders1
--       ((toAmt, toOrders), orders3)     = deleteFindMax orders2
--       fromOrder = 
--   in if fromAmt + toAmt < 0
--      then 
  
--   (fromAmt, fromOrders) <- 
--   (toAmt, toOrders) <- deleteFindMax $ _book_orders book
  
userBalances :: Exchange -> STM (M.Map UserId Balances)
userBalances = undefined

bookBalances :: Exchange -> STM Balances
bookBalances = undefined

userBookBalances :: Exchange -> UserId -> STM Balances
userBookBalances = undefined


--- SANITY CHECKS

-- consistency_noNegativeBalances :: ConsistencyCheck
-- consistency_noNegativeBalances = \exchange -> do
--   bals <- userBalances exchange
--   let checkUser (userId, balances) =
--         flip all (M.toList balances) $ \(currency, balance) ->
--         balance >= 0
--   return $ all checkUser $ M.toList bals

-- consistency_ordersBackedByAccount :: ConsistencyCheck
-- consistency_ordersBackedByAccount = \exchange -> do
--   usersBals <- userBalances exchange

--   let checkUserBalance :: Balances -> (Currency, Amount) -> Bool
--       checkUserBalance userBals (currency, bookAmount) =
--         case M.lookup currency userBals of
--           Nothing -> False
--           Just userAmount -> userAmount >= bookAmount

--   let checkUser :: (UserId, Balances) -> STM Bool
--       checkUser (user, userBals) = do
--         bookBals <- userBookBalances exchange user
--         let currenciesPending = M.toList bookBals
--         return $ all (checkUserBalance userBals) currenciesPending
--   allM checkUser $ M.toList usersBals

-- consistency_allCurrenciesExist :: ConsistencyCheck
-- consistency_allCurrenciesExist = \exchange -> do
--   usersBals <- userBalances exchange
--   bookBals <- bookBalances exchange
--   let valid currency = currency `elem` allCurrencies
--       checkBals bals = all valid $ M.keys bals
--       usersCheck = all checkBals usersBals
--       booksCheck = all valid $ M.keys bookBals
--   return $ usersCheck && booksCheck

-- consistency_noSelfTrades :: ConsistencyCheck
-- consistency_noSelfTrades = \exchange -> do
--   trades <- readTVar $ _exchange_trades exchange
--   return $ all checkTrade trades
--   where
--     checkTrade Trade{..} = _de_user _trade_from /= _de_user _trade_to
  

-- installSanityChecks :: Exchange -> IO ()
-- installSanityChecks exchange =
--   atomically $ mapM_ installCheck [
--     consistency_noNegativeBalances,
--     consistency_ordersBackedByAccount,
--     consistency_allCurrenciesExist,
--     consistency_noSelfTrades
--   ]
--   where
--     installCheck check = always $ check exchange
-- Returns the highest bid, lowest ask, and the book with them removed.
