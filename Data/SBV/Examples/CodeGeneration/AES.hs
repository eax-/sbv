-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Examples.CodeGeneration.AES
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- An implementation of AES (Advanced Encryption Standard), using SBV.
-- For details on AES, see FIPS-197: <http://csrc.nist.gov/publications/fips/fips197/fips-197.pdf>.
--
-- We do a T-box implementation, which leads to good C code as we can take
-- advantage of look-up tables. Note that we make virtually no attempt to
-- optimize our Haskell code. The concern here is not with getting Haskell running
-- fast at all. The idea is to program the T-Box implementation as naturally and clearly
-- as possible in Haskell, and have SBV's code-generator generate fast C code automatically.
-- Therefore, we merely use ordinary Haskell lists as our data-structures, and do not
-- bother with any unboxing or strictness annotations. Thus, we achieve the separation
-- of concerns: Correctness via clairty and simplicity and proofs on the Haskell side,
-- performance by relying on SBV's code generator. If necessary, the generated code
-- can be FFI'd back into Haskell to complete the loop.
--
-- All 3 valid key sizes (128, 192, and 256) as required by the FIPS-197 standard
-- are supported.
-----------------------------------------------------------------------------

{-# LANGUAGE ParallelListComp #-}

module Data.SBV.Examples.CodeGeneration.AES where

import Data.SBV
import Data.List (transpose)

-----------------------------------------------------------------------------
-- * Formalizing GF(2^8)
-----------------------------------------------------------------------------

-- | An element of the Galois Field 2^8, which are essentially polynomials with
-- maximum degree 7. They are conveniently represented as values between 0 and 255.
type GF28 = SWord8

-- | Addition in GF(2^8). Addition corresponds to simple 'xor'. Note that we
-- define it for vectors of GF(2^8) values, as that version is more convenient to
-- use in AES.
gf28Add :: [GF28] -> [GF28] -> [GF28]
gf28Add = zipWith xor

-- | Multiplication in GF(2^8). This is simple polynomial multipliation, followed
-- by the irreducible polynomial @x^8+x^5+x^3+x^1+1@. We simply use the 'pMult'
-- function exported by SBV to do the operation. 
gf28Mult :: GF28 -> GF28 -> GF28
gf28Mult x y = pMult (x, y, [8, 4, 3, 1, 0])

-- | Exponentiation by a constant in GF(2^8). The implementation uses the usual
-- square-and-multiply trick to speed up the computation.
gf28Pow :: GF28 -> Int -> GF28
gf28Pow n k = pow k
  where sq x  = x `gf28Mult` x
        pow 0    = 1
        pow i
         | odd i = n `gf28Mult` sq (pow (i `shiftR` 1))
         | True  = sq (pow (i `shiftR` 1))

-- | Computing inverses in GF(2^8). By the mathematical properties of GF(2^8)
-- and the particular irreducible polynomial used @x^8+x^5+x^3+x^1+1@, it
-- turns out that raising to the 254 power gives us the multiplicative inverse.
-- Of course, we can prove this using SBV:
--
-- >>> prove $ \x -> x ./= 0 ==> x `gf28Mult` gf28Inverse x .== 1
-- Q.E.D.
--
-- Note that we exclude @0@ in our theorem, as it does not have a
-- multiplicative inverse.
gf28Inverse :: GF28 -> GF28
gf28Inverse x = x `gf28Pow` 254

-----------------------------------------------------------------------------
-- * Implementing AES
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- ** Types and basic operations
-----------------------------------------------------------------------------
-- | AES state. The state consists of four 32-bit words, each of which is in turn treated
-- as four GF28's, i.e., 4 bytes. The T-Box implementation keeps the four-bytes together
-- for efficient representation.
type State = [SWord32]

-- | The key, which can be 128, 192, or 256 bits. Represented as a sequence of 32-bit words.
type Key = [SWord32]

-- | The key schedule. AES executes in rounds, and it treats first and last round keys slightly
-- differently than the middle ones. We reflect that choice by being explicit about it in our type.
-- The length of the middle list of keys depends on the key-size, which in turn determines
-- the number of rounds.
type KS = (Key, [Key], Key)

-- | Conversion from 32-bit words to 4 constituent bytes.
toBytes :: SWord32 -> [GF28]
toBytes x = [x1, x2, x3, x4]
        where (h,  l)  = split x
              (x1, x2) = split h
              (x3, x4) = split l

-- | Conversion from 4 bytes, back to a 32-bit row, inverse of 'toBytes' above. We
-- have the following simple theorems stating this relationship formally:
--
-- >>> prove $ \a b c d -> toBytes (fromBytes [a, b, c, d]) .== [a, b, c, d]
-- Q.E.D.
--
-- >>> prove $ \r -> fromBytes (toBytes r) .== r
-- Q.E.D.
fromBytes :: [GF28] -> SWord32
fromBytes [x1, x2, x3, x4] = (x1 # x2) # (x3 # x4)
fromBytes xs               = error $ "fromBytes: Unexpected input: " ++ show xs

-- | Rotating a state row by a fixed amount to the right.
rotR :: [GF28] -> Int -> [GF28]
rotR [a, b, c, d] 1 = [d, a, b, c]
rotR [a, b, c, d] 2 = [c, d, a, b]
rotR [a, b, c, d] 3 = [b, c, d, a]
rotR xs           i = error $ "rotR: Unexpected input: " ++ show (xs, i)

-----------------------------------------------------------------------------
-- ** The key schedule
-----------------------------------------------------------------------------

-- | Definition of round-constants, as specified in Section 5.2 of the AES standard.
rcon :: Int -> [GF28]
rcon i = [roundConstants !! i, 0, 0, 0]
 where roundConstants :: [GF28]
       roundConstants = 0 : [ gf28Pow 2 (k-1) | k <- [1 .. ] ]

-- | The @SubWord@ function, as specified in Section 5.2 of the AES standard.
subWord :: [GF28] -> [GF28]
subWord = map sbox

-- | The @RotWord@ function, as specified in Section 5.2 of the AES standard.
rotWord :: [GF28] -> [GF28]
rotWord [a, b, c, d] = [b, c, d, a]
rotWord xs           = error $ "rotWord: Unexpected input: " ++ show xs

-- | The @InvMixColumns@ transformation, as described in Section 5.3.3 of the standard. Note
-- that this transformation is only used explicitly during key-expansion in the T-Box implementation
-- of AES.
invMixColumns :: State -> State
invMixColumns state = map fromBytes $ transpose $ mmult (map toBytes state)
 where dot v = foldr1 xor . zipWith gf28Mult v
       mmult n = [map (dot r) n | r <- [ [0xe, 0xb, 0xd, 0x9]
                                       , [0x9, 0xe, 0xb, 0xd]
                                       , [0xd, 0x9, 0xe, 0xb]
                                       , [0xb, 0xd, 0x9, 0xe]
                                       ]]

-- | Key expansion. Starting with the given key, returns an infinite sequence of
-- words, as described by the AES standard, Section 5.2, Figure 11.
keyExpansion :: Int -> Key -> [Key]
keyExpansion nk key = chop4 (map fromBytes keys)
   where keys :: [[GF28]]
         keys = map toBytes key ++ [nextWord i prev old | i <- [nk ..] | prev <- drop (nk-1) keys | old <- keys]
         chop4 :: [a] -> [[a]]
         chop4 xs = let (f, r) = splitAt 4 xs in f : chop4 r
         nextWord :: Int -> [GF28] -> [GF28] -> [GF28]
         nextWord i prev old
           | i `mod` nk == 0           = old `gf28Add` (subWord (rotWord prev) `gf28Add` rcon (i `div` nk))
           | i `mod` nk == 4 && nk > 6 = old `gf28Add` (subWord prev)
           | True                      = old `gf28Add` prev

-----------------------------------------------------------------------------
-- ** The S-box transformation
-----------------------------------------------------------------------------

-- | The values of the AES S-box table. Note that we describe the S-box programmatically
-- using the mathematical construction given in Section 5.1.1 of the standard. However,
-- the code-generation will turn this into a mere look-up table, as it is just a
-- constant table, all computation being done at \"compile-time\".
sboxTable :: [GF28]
sboxTable = [xformByte (gf28Inverse b) | b <- [0 .. 255]]
  where xformByte :: GF28 -> GF28
        xformByte b = foldr xor 0x63 [b `rotateR` i | i <- [0, 4, 5, 6, 7]]

-- | The sbox transformation. We simply select from the sbox table. Note that we
-- are obliged to give a default value (here @0@) to be used if the index is out-of-bounds
-- as required by SBV's 'select' function. However, that will never happen since
-- the table has all 256 elements in it.
sbox :: GF28 -> GF28
sbox = select sboxTable 0


-----------------------------------------------------------------------------
-- ** The inverse S-box transformation
-----------------------------------------------------------------------------

-- | The values of the inverse S-box table. Again, the construction is programmatic.
unSBoxTable :: [GF28]
unSBoxTable = [gf28Inverse (xformByte b) | b <- [0 .. 255]]
  where xformByte :: GF28 -> GF28
        xformByte b = foldr xor 0x05 [b `rotateR` i | i <- [2, 5, 7]]

-- | The inverse s-box transformation.
unSBox :: GF28 -> GF28
unSBox = select unSBoxTable 0

-----------------------------------------------------------------------------
-- ** AddRoundKey transformation
-----------------------------------------------------------------------------

-- | Adding the round-key to the current state. We simply exploit the fact
-- that addition is just xor in implementing this transformation.
addRoundKey :: Key -> State -> State
addRoundKey = zipWith xor

-----------------------------------------------------------------------------
-- ** Tables for T-Box encryption
-----------------------------------------------------------------------------

-- | T-box table generation function.for encryption
t0Func :: GF28 -> [GF28]
t0Func a = [s `gf28Mult` 2, s, s, s `gf28Mult` 3] where s = sbox a

-- | First look-up table used in encryption
t0 :: GF28 -> SWord32
t0 = select t0Table 0 where t0Table = [fromBytes (t0Func a)          | a <- [0..255]]

-- | Second look-up table used in encryption
t1 :: GF28 -> SWord32
t1 = select t1Table 0 where t1Table = [fromBytes (t0Func a `rotR` 1) | a <- [0..255]]

-- | Third look-up table used in encryption
t2 :: GF28 -> SWord32
t2 = select t2Table 0 where t2Table = [fromBytes (t0Func a `rotR` 2) | a <- [0..255]]

-- | Fourth look-up table used in encryption
t3 :: GF28 -> SWord32
t3 = select t3Table 0 where t3Table = [fromBytes (t0Func a `rotR` 3) | a <- [0..255]]

-----------------------------------------------------------------------------
-- ** Tables for T-Box decryption
-----------------------------------------------------------------------------

-- | T-box table generating function for decryption
u0Func :: GF28 -> [GF28]
u0Func a = [s `gf28Mult` 0xE, s `gf28Mult` 0x9, s `gf28Mult` 0xD, s `gf28Mult` 0xB] where s = unSBox a

-- | First look-up table used in decryption
u0 :: GF28 -> SWord32
u0 = select t0Table 0 where t0Table = [fromBytes (u0Func a)          | a <- [0..255]]

-- | Second look-up table used in decryption
u1 :: GF28 -> SWord32
u1 = select t1Table 0 where t1Table = [fromBytes (u0Func a `rotR` 1) | a <- [0..255]]

-- | Third look-up table used in decryption
u2 :: GF28 -> SWord32
u2 = select t2Table 0 where t2Table = [fromBytes (u0Func a `rotR` 2) | a <- [0..255]]

-- | Fourth look-up table used in decryption
u3 :: GF28 -> SWord32
u3 = select t3Table 0 where t3Table = [fromBytes (u0Func a `rotR` 3) | a <- [0..255]]

-----------------------------------------------------------------------------
-- ** AES rounds
-----------------------------------------------------------------------------

-- | Generic round function. Given the function to perform one round, a key-schedule,
-- and a starting state, it performs the AES rounds.
doRounds :: (Bool -> State -> Key -> State) -> KS -> State -> State
doRounds rnd (ikey, rkeys, fkey) sIn = rnd True (last rs) fkey
  where s0 = ikey `addRoundKey` sIn
        rs = s0 : [rnd False s k | s <- rs | k <- rkeys ]

-- | One encryption round. The first argument indicates whether this is the final round
-- or not, in which case the construction is slightly different.
aesRound :: Bool -> State -> Key -> State
aesRound isFinal s key = d `addRoundKey` key
  where d = map (f isFinal) [0..3]
        a = map toBytes s
        f True j = e0 `xor` e1 `xor` e2 `xor` e3
              where e0 = fromBytes [sbox (a !! ((j+0) `mod` 4) !! 0), 0, 0, 0]
                    e1 = fromBytes [0, sbox (a !! ((j+1) `mod` 4) !! 1), 0, 0]
                    e2 = fromBytes [0, 0, sbox (a !! ((j+2) `mod` 4) !! 2), 0]
                    e3 = fromBytes [0, 0, 0, sbox (a !! ((j+3) `mod` 4) !! 3)]
        f False j = e0 `xor` e1 `xor` e2 `xor` e3
              where e0 = t0 (a !! ((j+0) `mod` 4) !! 0)
                    e1 = t1 (a !! ((j+1) `mod` 4) !! 1)
                    e2 = t2 (a !! ((j+2) `mod` 4) !! 2)
                    e3 = t3 (a !! ((j+3) `mod` 4) !! 3)

-- | One decryption round. Similar to the encryption round, the first argument
-- indicates whether this is the final round or not.
aesInvRound :: Bool -> State -> Key -> State
aesInvRound isFinal s key = d `addRoundKey` key
  where d = map (f isFinal) [0..3]
        a = map toBytes s
        f True j = e0 `xor` e1 `xor` e2 `xor` e3
              where e0 = fromBytes [unSBox (a !! ((j+0) `mod` 4) !! 0), 0, 0, 0]
                    e1 = fromBytes [0, unSBox (a !! ((j+3) `mod` 4) !! 1), 0, 0]
                    e2 = fromBytes [0, 0, unSBox (a !! ((j+2) `mod` 4) !! 2), 0]
                    e3 = fromBytes [0, 0, 0, unSBox (a !! ((j+1) `mod` 4) !! 3)]
        f False j = e0 `xor` e1 `xor` e2 `xor` e3
              where e0 = u0 (a !! ((j+0) `mod` 4) !! 0)
                    e1 = u1 (a !! ((j+3) `mod` 4) !! 1)
                    e2 = u2 (a !! ((j+2) `mod` 4) !! 2)
                    e3 = u3 (a !! ((j+1) `mod` 4) !! 3)

-----------------------------------------------------------------------------
-- * AES API
-----------------------------------------------------------------------------

-- | Key schedule. Given a 128, 192, or 256 bit key, expand it to get key-schedules
-- for encryption and decryption. The key is given as a sequence of 32-bit words.
-- (4 elements for 128-bits, 6 for 192, and 8 for 256.)
aesKeySchedule :: Key -> (KS, KS)
aesKeySchedule key
  | nk `elem` [4, 6, 8]
  = (encKS, decKS)
  | True
  = error "aesKeySchedule: Invalid key size"
  where nk = length key
        nr = nk + 6
        encKS@(f, m, l) = (head rKeys, take (nr-1) (tail rKeys), rKeys !! nr)
        decKS = (l, map invMixColumns (reverse m), f)
        rKeys = keyExpansion nk key

-- | Block encryption. The first argument is the plain-text, which must have
-- precisely 4 elements, for a total of 128-bits of input. The second
-- argument is the key-schedule to be used, obtained by a call to 'aesKeySchedule'.
-- The output will always have 4 32-bit words, which is the cipher-text.
aesEncrypt :: [SWord32] -> KS -> [SWord32]
aesEncrypt pt encKS
  | length pt == 4
  = doRounds aesRound encKS pt
  | True
  = error "aesEncrypt: Invalid plain-text size"

-- | Block decryption. The arguments are the same as in 'aesEncrypt', except
-- the first argument is the cipher-text and the output is the corresponding
-- plain-text.
aesDecrypt :: [SWord32] -> KS -> [SWord32]
aesDecrypt ct decKS
  | length ct == 4
  = doRounds aesInvRound decKS ct
  | True
  = error "aesDecrypt: Invalid cipher-text size"

-----------------------------------------------------------------------------
-- * Test vectors
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- ** 128-bit enc/dec test
-----------------------------------------------------------------------------

-- | 128-bit encryption test, from Appendix C.1 of the AES standard:
--
-- >>> map hex t128Enc
-- ["69c4e0d8","6a7b0430","d8cdb780","70b4c55a"]
--
t128Enc :: [SWord32]
t128Enc = aesEncrypt pt ks
  where pt  = [0x00112233, 0x44556677, 0x8899aabb, 0xccddeeff]
        key = [0x00010203, 0x04050607, 0x08090a0b, 0x0c0d0e0f]
        (ks, _) = aesKeySchedule key

-- | 128-bit decryption test, from Appendix C.1 of the AES standard:
--
-- >>> map hex t128Dec
-- ["00112233","44556677","8899aabb","ccddeeff"]
--
t128Dec :: [SWord32]
t128Dec = aesDecrypt ct ks
  where ct  = [0x69c4e0d8, 0x6a7b0430, 0xd8cdb780, 0x70b4c55a]
        key = [0x00010203, 0x04050607, 0x08090a0b, 0x0c0d0e0f]
        (_, ks) = aesKeySchedule key

-----------------------------------------------------------------------------
-- ** 192-bit enc/dec test
-----------------------------------------------------------------------------

-- | 192-bit encryption test, from Appendix C.2 of the AES standard:
--
-- >>> map hex t192Enc
-- ["dda97ca4","864cdfe0","6eaf70a0","ec0d7191"]
--
t192Enc :: [SWord32]
t192Enc = aesEncrypt pt ks
  where pt  = [0x00112233, 0x44556677, 0x8899aabb, 0xccddeeff]
        key = [0x00010203, 0x04050607, 0x08090a0b, 0x0c0d0e0f, 0x10111213, 0x14151617]
        (ks, _) = aesKeySchedule key

-- | 192-bit decryption test, from Appendix C.2 of the AES standard:
--
-- >>> map hex t192Dec
-- ["00112233","44556677","8899aabb","ccddeeff"]
--
t192Dec :: [SWord32]
t192Dec = aesDecrypt ct ks
  where ct  = [0xdda97ca4, 0x864cdfe0, 0x6eaf70a0, 0xec0d7191]
        key = [0x00010203, 0x04050607, 0x08090a0b, 0x0c0d0e0f, 0x10111213, 0x14151617]
        (_, ks) = aesKeySchedule key

-----------------------------------------------------------------------------
-- ** 256-bit enc/dec test
-----------------------------------------------------------------------------

-- | 256-bit encryption, from Appendix C.3 of the AES standard:
--
-- >>> map hex t256Enc
-- ["8ea2b7ca","516745bf","eafc4990","4b496089"]
--
t256Enc :: [SWord32]
t256Enc = aesEncrypt pt ks
  where pt  = [0x00112233, 0x44556677, 0x8899aabb, 0xccddeeff]
        key = [0x00010203, 0x04050607, 0x08090a0b, 0x0c0d0e0f, 0x10111213, 0x14151617, 0x18191a1b, 0x1c1d1e1f]
        (ks, _) = aesKeySchedule key

-- | 256-bit decryption, from Appendix C.3 of the AES standard:
--
-- >>> map hex t256Dec
-- ["00112233","44556677","8899aabb","ccddeeff"]
--
t256Dec :: [SWord32]
t256Dec = aesDecrypt ct ks
  where ct  = [0x8ea2b7ca, 0x516745bf, 0xeafc4990, 0x4b496089]
        key = [0x00010203, 0x04050607, 0x08090a0b, 0x0c0d0e0f, 0x10111213, 0x14151617, 0x18191a1b, 0x1c1d1e1f]
        (_, ks) = aesKeySchedule key


-----------------------------------------------------------------------------
-- * Verification
-- ${verifIntro}
-----------------------------------------------------------------------------
{- $verifIntro
  While SMT based technologies can prove correct many small properties fairly quickly, it would
  be naive for them to automatically verify that our AES implementation is correct. (By correct,
  we mean decryption follewed by encryption yielding the same result.) However, we can state
  this property precisely using SBV, and use quick-check to gain some confidence.
-}

-- | Correctness theorem for 128-bit AES. Ideally, we would run:
--
-- @
--   prove aes128IsCorrect
-- @
--
-- to get a proof automatically. Unfortunately, while SBV will successfully generate the proof
-- obligation for this theorem and ship it to the SMT solver, it would be naive to expect the SMT-solver
-- to finish that proof in any reasonable time with the currently available SMT solving technologies.
-- Instead, we can issue:
--
-- @
--   quickCheck aes128IsCorrect
-- @
-- 
-- and get some degree of confidence in our code. Similar predicates can be easily constructed for 192, and
-- 256 bit cases as well.
aes128IsCorrect :: (SWord32, SWord32, SWord32, SWord32)  -- ^ plain-text words
                -> (SWord32, SWord32, SWord32, SWord32)  -- ^ key-words
                -> SBool                                 -- ^ True if round-trip gives us plain-text back
aes128IsCorrect (i0, i1, i2, i3) (k0, k1, k2, k3) = pt .== pt'
   where pt  = [i0, i1, i2, i3]
         key = [k0, k1, k2, k3]
         (encKS, decKS) = aesKeySchedule key
         ct  = aesEncrypt pt encKS
         pt' = aesDecrypt ct decKS

-----------------------------------------------------------------------------
-- * Code generation
-- ${codeGenIntro}
-----------------------------------------------------------------------------
{- $codeGenIntro
   We have emphasized that our T-Box implementation in Haskell was guided by clarity and correctness, not
   performance. Indeed, our implementation is hardly the fastest AES implementation in Haskell. However,
   we can use it to automatically generate straight-line C-code that can run fairly fast.

   For the purposes of illustration, we only show here how to generate code for a 128-bit AES block-encrypt
   function, that takes 8 32-bit words as an argument. The first 4 are the 128-bit input, and the final
   four are the 128-bit key. The impact of this is that the generated function would expand the key for
   each block of encryption, a needless task unless we change the key in every block. In a more serios application,
   we would instead generate code for both the 'aesKeySchedule' and the 'aesEncrypt' functions, thus reusing the
   key-schedule over many applications of the encryption call. (Unfortunately doing this is rather cumbersome right
   now, since Haskell does not support fixed-size lists.)
-}

-- | Code generation for 128-bit AES encryption.
--
-- The following sample from the generated code-lines show how T-Boxes are rendered as C arrays:
--
-- @
--   static const SWord32 table1[] = {
--       0xc66363a5UL, 0xf87c7c84UL, 0xee777799UL, 0xf67b7b8dUL,
--       0xfff2f20dUL, 0xd66b6bbdUL, 0xde6f6fb1UL, 0x91c5c554UL,
--       0x60303050UL, 0x02010103UL, 0xce6767a9UL, 0x562b2b7dUL,
--       0xe7fefe19UL, 0xb5d7d762UL, 0x4dababe6UL, 0xec76769aUL,
--       ...
--       }
-- @
--
-- The generated program has 5 tables (one sbox table, and 4-Tboxes), all converted to fast C arrays. Here
-- is a sample of the generated straightline C-code:
--
-- @
--   const SWord32 s1066 = s2 ^ s1065;
--   const SWord16 s1067 = (SWord16) s1066;
--   const SWord8  s1068 = (SWord8) (s1067 >> 8);
--   const SWord32 s1069 = table3[s1068];
--   const SWord32 s1070 = s801 ^ s1069;
--   const SWord16 s1326 = (SWord16) (s7 >> 16);
--   const SWord8  s1327 = (SWord8) (s1326 >> 8);
-- @
--
-- The GNU C-compiler does a fine job of optimizing this straightline code to generate a fairly efficient C implementation.
cgAES128BlockEncrypt :: IO ()
cgAES128BlockEncrypt = compileToC True Nothing "aes128BlockEncrypt" args enc
  where args     = inpWords ++ keyWords
        inpWords = ["pt0", "pt1", "pt2", "pt3"]         -- names to use in the generated C prototype for the plain-text words
        keyWords = ["key0", "key1", "key2", "key3"]     -- ditto for key-words
        -- NB. The following can be written much more nicely once we have type-naturals added to GHC
        enc (pt0, pt1, pt2, pt3, key0, key1, key2, key3) = (ct0, ct1, ct2, ct3)
          where key = [key0, key1, key2, key3]
                pt  = [pt0, pt1, pt2, pt3]
                (encKS, _) = aesKeySchedule key
                [ct0, ct1, ct2, ct3] = aesEncrypt pt encKS
