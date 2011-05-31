-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.BitVectors.STree
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Implementation of full-binary symbolic trees, providing logarithmic
-- time access to elements. Both reads and writes are supported.
-----------------------------------------------------------------------------

{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Data.SBV.BitVectors.STree (STree, readSTree, writeSTree, mkSTree) where

import Data.Bits (Bits(..))

import Data.SBV.BitVectors.Data
import Data.SBV.BitVectors.Model

-- | A symbolic tree containing values of type e, indexed by
-- elements of type i. Note that these trees are always full,
-- i.e., their shape is constant. They are useful when dealing
-- with data-structures that are indexed with symbolic values,
-- and where access time is important. 'STree' structures provide
-- logarithmic time reads and writes.
data STree i e = SLeaf e
               | SBin  (STree i e) (STree i e)
               deriving Show

instance Mergeable e => Mergeable (STree i e) where
  symbolicMerge b (SLeaf i)  (SLeaf j)    = SLeaf (ite b i j)
  symbolicMerge b (SBin l r) (SBin l' r') = SBin  (ite b l l') (ite b r r')
  symbolicMerge _ _          _            = error $ "SBV.STree.symbolicMerge: Impossible happened while merging states"

-- | Reading a value. We bit-blast the index and descend down the full tree
-- according to bit-values.
readSTree :: (Bits i, SymWord i, SymWord e) => STree (SBV i) (SBV e) -> SBV i -> SBV e
readSTree s i = walk (blastBE i) s
  where walk []     (SLeaf v)  = v
        walk (b:bs) (SBin l r) = ite b (walk bs r) (walk bs l)
        walk _      _          = error $ "SBV.STree.readSTree: Impossible happened while reading: " ++ show i

-- | Writing a value. Similar to how reads are done. The important thing is that the tree
-- representation keeps updates to a minimum.
writeSTree :: (Bits i, SymWord i, SymWord e) => STree (SBV i) (SBV e) -> SBV i -> SBV e -> STree (SBV i) (SBV e)
writeSTree s i j = walk (blastBE i) s
  where walk []     _          = SLeaf j
        walk (b:bs) (SBin l r) = SBin (ite b l (walk bs l)) (ite b (walk bs r) r)
        walk _      _          = error $ "SBV.STree.writeSTree: Impossible happened while reading: " ++ show i

-- | Construct the fully balanced initial tree using the given values
mkSTree :: forall i e. HasSignAndSize i => [SBV e] -> STree (SBV i) (SBV e)
mkSTree ivals
  | reqd /= given = error $ "SBV.STree.mkSTree: Required " ++ show reqd ++ " elements, received: " ++ show given
  | True          = go ivals
  where reqd = 2 ^ (sizeOf (undefined :: i))
        given = length ivals
        go []  = error $ "SBV.STree.mkSTree: Impossible happened, ran out of elements"
        go [l] = SLeaf l
        go ns  = let (l, r) = splitAt (length ns `div` 2) ns in SBin (go l) (go r)
