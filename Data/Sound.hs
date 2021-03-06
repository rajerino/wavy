
-- | Core sound module.
module Data.Sound (
   -- * Basic types
   Time, Sample
 , Sound
   -- * Basic functions
 , duration , rate
 , channels , nSamples
 , sample

   -- * Wave generators
   -- ** Basic wave generators
 , zeroSound , zeroSoundR
 , sine      , sineR
 , sawtooth  , sawtoothR
 , square    , squareR
 , triangle  , triangleR
   -- ** Variable Frequency Basic wave generators
 , sineV     , sineVR
   -- ** Functional wave generators
 , fromFunction
   -- ** Other wave generators
 , noise   , noiseR
 , karplus , karplusR

   -- * Sound operators
   -- ** Basic operators
 , (<.>) , (<+>) , (<|>)
   -- ** Other operators
 , parWithPan , addAt

   -- * Modifiers
 , addSilenceBeg , addSilenceEnd
 , velocity , mapSound
 , pan , scale
 , divide , multiply
 , left , right

   -- * Effects
 , echo
   -- * Utils
 , loop
   ) where

import Data.Monoid
import Data.Sound.Internal
import Data.Sound.Container.Chunks
-- Lists
import Data.List (unfoldr)
-- Random
import System.Random

-- | Add a silence at the beginning of a sound.
addSilenceBeg :: Time -- ^ Duration of the silence.
              -> Sound -> Sound
addSilenceBeg d s = multiply n (zeroSoundR r d) <.> s
 where
  r = rate s
  n = channels s

-- | Add a silence at the end of a sound.
addSilenceEnd :: Time -- ^ Duration of the silence.
              -> Sound -> Sound
addSilenceEnd d s = s <.> multiply n (zeroSoundR r d)
 where
  r = rate s
  n = channels s

-- | /Addition of sounds/. If one sound is longer, the remainder will remain without any change.
--   There are some restriction to use this function.
--
--   * Both arguments must share the same /sample rate/.
--
--   * Both arguments must share the same /number of channels/.
(<+>) :: Sound -> Sound -> Sound
s1@(S r l nc c) <+> s2@(S r' l' nc' c')
 | r  /= r'  = soundError [s1,s2] "<+>" $ "Can't add sounds with different sample rates. "
                                       ++ "Please, consider to change the sample rate of one of them."
 | nc /= nc' = soundError [s1,s2] "<+>" $ "Can't add two sounds with different number of channels. "
                                       ++ "Please, consider to change the number of channels in one of them."
 | otherwise = S r (max l l') nc $ zipChunks (zipWith (+)) c c'

-- | /Parallelization of sounds/. Often refered as the /par/ operator.
--   Applying this operator over two sounds will make them sound at the same
--   time, but in different channels. The sound at the left will be at left-most
--   channels, and the right one at the right-most channels.
--   There are some restriction to use this function.
--
--   * Both arguments must share the same /sample rate/.
--
(<|>) :: Sound -> Sound -> Sound
s1@(S r l nc c) <|> s2@(S r' l' nc' c')
 | r  /= r'  = soundError [s1,s2] "<|>" $ "Can't par sounds with different sample rates. "
                                       ++ "Please, consider to change the sample rate of one of them."
 | otherwise = let c'' = if l < l' then zipChunks (<>) (c <> zeroChunks (l' - l) nc) c'
                                   else zipChunks (<>) c (c' <> zeroChunks (l-l') nc')
               in  S r (max l l') (nc+nc') c''

{- About the associativity of the sequencing operator.

If we are using balaced chunk appending, the sequencing operator (>.) should be
left associative (infixl). Suppose we have three sound chunks of size n. When we
append two chunks, the right chunk gets balanced (unless it is already balanced)
in order to get a balanced chunk after the appending. This makes balancing have
at most n steps where n is the length of the right argument.

If we compare the number of balancing steps with left and right association,
we observe that, if the inputs are of similar size, it is better to associate
to the left.

        n                  n                     n
(--------------- <.> ---------------) <.> ---------------
=> n balancing steps
              2n                          n
------------------------------ <.> ---------------
=> n balancing steps
                    3n
---------------------------------------------

Total balancing steps: 2n

        n                   n                   n
--------------- <.> (--------------- <.> ---------------)
=> n balancing steps
        n                        2n
--------------- <.> ------------------------------
=> 2n balancing steps
                    3n
---------------------------------------------

Total balancing steps: 3n

Priority 5 is just a provisional number (very arbitrary).

-}

infixl 5 <.>

-- | /Sequencing of sounds/. The sequencing operator, as the name says, sequences a couple of
--   sounds.
--   There are some restriction to use this function.
--
--   * Both arguments must share the same /sample rate/.
--
--   * Both arguments must share the same /number of channels/.
(<.>) :: Sound -> Sound -> Sound
s1@(S r l nc c) <.> s2@(S r' l' nc' c')
 | r  /= r'  = soundError [s1,s2] ">." $ "Can't sequence sounds with different sample rates. "
                                      ++ "Please, consider to change the sample rate of one of them."
 | nc /= nc' = soundError [s1,s2] ">." $ "Can't sequence two sounds with different number of channels. "
                                      ++ "Please, consider to change the number of channels in one of them."
 | otherwise = S r (l+l') nc $ c <> c'

{-# RULES
"sound/multiplyFunction"
   forall n r d p f. multiply n (fromFunction r d p f) = fromFunction r d p (concat . replicate n . f)
  #-}

-- | Multiply a sound over different channels. It will be just repeated over the different channels
--   with the same amplitude (unlike 'divide'). The number of channels will be multiplied by the
--   given factor.
--
-- > multiply n (fromFunction r d p f) = fromFunction r d p (concat . replicate n . f)
--
multiply :: Int -- ^ Number of channels factor.
         -> Sound -> Sound
{-# NOINLINE multiply #-}
multiply n s = f 1
 where
  f k = if k == n then s else s <|> f (k+1)

-- | Similar to 'multiply', but also dividing the amplitude of the sound by the factor.
divide :: Int -- ^ Number of channels factor.
       -> Sound -> Sound
{-# INLINE divide #-}
divide n s = let s' = multiply n s
             in  scale (1/n') s'
 where
  n' = fromIntegral n

-- | This function works like '<+>', but it allows you to choose at which time add the sound.
--   This way, @insertAt t s1 s2@ will add @s1@ to @s2@ starting at the second @t@.
addAt :: Time -> Sound -> Sound -> Sound
addAt t s1 s2 = addSilenceBeg t s1 <+> s2

{-# RULES
"sound/velocity" forall f g s. velocity f (velocity g s) = velocity (\t -> f t * g t) s
  #-}

-- | Time-dependent amplitude modifier.
--
-- > velocity f (velocity g s) = velocity (\t -> f t * g t) s
--
velocity :: (Time -> Double) -- ^ @0 <= v t <= 1@.
         -> Sound
         -> Sound
{-# INLINE velocity #-}
velocity v s = mapSoundAt (\i -> fmap $ \x -> v (f i) * x) s
 where
  r = rate s
  f = sampleTime r

-- | Scale a sound by a given factor.
--
-- > scale = velocity . const
scale :: Double -- ^ Scaling factor. @0 <= k <= 1@
      -> Sound  -- ^ Original sound.
      -> Sound  -- ^ Scaled sound.
{-# INLINE scale #-}
scale = velocity . const

-- | Similar to the /par operator/ ('<|>') but using a time-dependent panning function.
--
-- > parWithPan (const (-1)) s1 s2 =              s1         <|>                     s2
-- > parWithPan (const   0 ) s1 s2 = scale (1/2) (s1 <+> s2) <|> scale (1/2) (s1 <+> s2)
-- > parWithPan (const   1 ) s1 s2 =                     s2  <|>              s1
--
parWithPan :: (Time -> Double) -- ^ @-1 <= p t <= 1@.
           -> Sound
           -> Sound
           -> Sound
{-# INLINE parWithPan #-}
parWithPan p s1 s2 = l <|> r
 where
  -- Can we combine velocity calls so we only need to call it twice?
  l = velocity (\t -> (1 - p t) / 2) s1 <+> velocity (\t -> (1 + p t) / 2 ) s2
  r = velocity (\t -> (1 + p t) / 2) s1 <+> velocity (\t -> (1 - p t) / 2 ) s2

-- | Pan a sound from left (-1) to right (1) with a time-dependent function.
pan :: (Time -> Double) -- ^ @-1 <= p t <= 1@.
    -> Sound
    -> Sound
pan p s = parWithPan p s $ zeroSoundR r $ duration s
 where
  r = rate s

-- | Move a sound completly to the left.
left :: Sound -> Sound
left s = s <|> mapSound (fmap $ const 0) s

-- | Move a sound completly to the right.
right :: Sound -> Sound
right s = mapSound (fmap $ const 0) s <|> s

{-# RULES
"sound/loop"    forall n m s. loop n (loop m s) = loop (n*m) s
"sound/mapLoop" forall f n s. mapSound f (loop n s) = loop n (mapSound f s)
  #-}

-- | Repeat a sound cyclically a given number of times.
--   It obeys the following rules:
--
-- > loop n (loop m s) = loop (n*m) s
-- > mapSound f (loop n s) = loop n (mapSound f s)
--
loop :: Int -> Sound -> Sound
loop n = foldr1 (<.>) . replicate n

-- ECHOING

-- | Echo effect.
echo :: Int    -- ^ Repetitions. How many times the sound is repeated.
     -> Double -- ^ Decay (@0 < decay < 1@). How fast the amplitude of the repetitions decays.
     -> Time   -- ^ Delay @0 < delay@. Time between repetitions.
     -> Sound  -- ^ Original sound.
     -> Sound  -- ^ Echo signal (without the original sound).
echo 0 _   _   s = s
echo n dec del s = foldr1 (<+>)
  [ scale (dec ^ i) $ addSilenceBeg (fromIntegral i * del) s | i <- [1 .. n] ]

{-
-- INTEGRATION (possibly useful in the future)

simpson :: Time -> Time -> (Time -> Double) -> Double
simpson a b f = (b-a) / 6 * (f a + 4 * f ((a+b)/2) + f b)

intervalWidth :: Time
intervalWidth = 0.1

integrate :: Time -> Time -> (Time -> Double) -> Double
integrate a b f = sum [ simpson i (i + intervalWidth) f | i <- [a , a + intervalWidth .. b - intervalWidth] ]
-}

-- Simpson integration error
--
-- 1/90 * (intervalWidth/2)^5 * abs (f''''(c))
--

---------------
-- COMMON WAVES

{- About the common waves definitions

Functions describing these common waves have been created using
usual definitions, but then algebraically transformed to use a
smaller number of operations.

-}

-- | Double of 'pi'.
pi2 :: Time
pi2 = 2*pi

timeFloor :: Time -> Time
timeFloor = fromIntegral . (floor :: Time -> Int) -- Don't use truncate!

decimals :: Time -> Time
decimals = snd . (properFraction :: Time -> (Int,Time))

-- | Like 'zeroSound', but allows you to choose the sample rate.
zeroSoundR :: Word32 -> Time -> Sound
{-# INLINE zeroSoundR #-}
zeroSoundR r d = S r n 1 $ zeroChunks n 1
 where
  n = timeSample r d

-- | Creates a mono and constantly null sound.
--
-- <<http://i.imgur.com/BP5PFIY.png>>
zeroSound :: Time -> Sound
{-# INLINE zeroSound #-}
zeroSound = zeroSoundR 44100

-- | Like 'sine', but allows you to choose the sample rate.
sineR :: Word32 -- ^ Sample rate
      -> Time   -- ^ Duration (0~)
      -> Double -- ^ Amplitude (0~1)
      -> Time   -- ^ Frequency (Hz)
      -> Time   -- ^ Phase
      -> Sound
{-# INLINE sineR #-}
sineR r d a f p = fromFunction r d (Just $ 1/f) $
  let pi2f = pi2*f
  in  \t ->
        let s :: Time
            s = pi2f*t + p
        in  [a * sin s]

-- | Create a sine wave with the given duration, amplitude, frequency and phase (mono).
--
-- <<http://i.imgur.com/46ry4Oq.png>>
sine :: Time   -- ^ Duration (0~)
     -> Double -- ^ Amplitude (0~1)
     -> Time   -- ^ Frequency (Hz)
     -> Time   -- ^ Phase
     -> Sound
{-# INLINE sine #-}
sine = sineR 44100

-- | Like 'sineV', but allows you to choose the sample rate.
sineVR :: Word32 -- ^ Sample rate
       -> Time   -- ^ Duration (0~)
       -> Double -- ^ Amplitude (0~1)
       -> (Time -> Time) -- ^ Frequency (Hz)
       -> Time   -- ^ Phase
       -> Sound
{-# INLINE sineVR #-}
sineVR r d a f p = fromFunction r d Nothing $
  \t -> let s :: Time
            s = pi2*f t*t + p
        in  [a * sin s]

-- | A variation of 'sine' with frequency that changes over time.
--   If you are going to use a constant frequency, consider to use
--   'sine' for a better performance.
sineV :: Time   -- ^ Duration (0~)
      -> Double -- ^ Amplitude (0~1)
      -> (Time -> Time) -- ^ Frequency (Hz)
      -> Time   -- ^ Phase
      -> Sound
{-# INLINE sineV #-}
sineV = sineVR 44100

-- | Like 'sawtooth', but allows you to choose the sample rate.
sawtoothR :: Word32 -- ^ Sample rate
          -> Time   -- ^ Duration (0~)
          -> Double -- ^ Amplitude (0~1)
          -> Time   -- ^ Frequency (Hz)
          -> Time   -- ^ Phase
          -> Sound
{-# INLINE sawtoothR #-}
sawtoothR r d a f p = fromFunction r d (Just $ 1/f) $ \t ->
 let s :: Time
     s = f*t + p
 in  [a * (2 * decimals s - 1)]

-- | Create a sawtooth wave with the given duration, amplitude, frequency and phase (mono).
--
-- <<http://i.imgur.com/uJVIpmv.png>>
sawtooth :: Time   -- ^ Duration (0~)
         -> Double -- ^ Amplitude (0~1)
         -> Time   -- ^ Frequency (Hz)
         -> Time   -- ^ Phase
         -> Sound
{-# INLINE sawtooth #-}
sawtooth = sawtoothR 44100

-- | Like 'square', but allows you to choose the sample rate.
squareR :: Word32 -- ^ Sample rate
        -> Time   -- ^ Duration (0~)
        -> Double -- ^ Amplitude (0~1)
        -> Time   -- ^ Frequency (Hz)
        -> Time   -- ^ Phase
        -> Sound
{-# INLINE squareR #-}
squareR r d a f p = fromFunction r d (Just $ 1/f) $ \t ->
 let s :: Time
     s = f*t + p
     h :: Time -> Double
     h x = signum $ 0.5 - x
 in  [a * h (decimals s)]

-- | Create a square wave with the given duration, amplitude, frequency and phase (mono).
--
-- <<http://i.imgur.com/GQUCVwT.png>>
square :: Time   -- ^ Duration (0~)
       -> Double -- ^ Amplitude (0~1)
       -> Time   -- ^ Frequency (Hz)
       -> Time   -- ^ Phase
       -> Sound
{-# INLINE square #-}
square = squareR 44100

-- | As in 'triangle', but allows you to choose the sample rate.
triangleR :: Word32 -- ^ Sample rate
          -> Time   -- ^ Duration (0~)
          -> Double -- ^ Amplitude (0~1)
          -> Time   -- ^ Frequency (Hz)
          -> Time   -- ^ Phase
          -> Sound
{-# INLINE triangleR #-}
triangleR r d a f p = fromFunction r d (Just $ 1/f) $ \t ->
 let s :: Time
     s = f*t + p
 in  [a * (1 - 4 * abs (timeFloor (s + 0.25) - s + 0.25))]

-- | Create a triange wave with the given duration, amplitude, frequency and phase (mono).
--
-- <<http://i.imgur.com/0RZ8gUh.png>>
triangle :: Time   -- ^ Duration (0~)
         -> Double -- ^ Amplitude (0~1)
         -> Time   -- ^ Frequency (Hz)
         -> Time   -- ^ Phase
         -> Sound
{-# INLINE triangle #-}
triangle = triangleR 44100

-------------------
-- OTHER SYNTHS

-- | Like 'noise', but allows you to choose the sample rate.
noiseR :: Word32 -- ^ Sample rate
       -> Time   -- ^ Duration (0~)
       -> Double -- ^ Amplitude (0~1)
       -> Time   -- ^ Frequency (Hz)
       -> Int    -- ^ Random seed
       -> Sound
noiseR r d a f sd = S r tn 1 cs
 where
  n = timeSample r $ recip f
  xs = unfoldr (\(i,g) -> if i > n then Nothing
                                   else let (x,g') = randomR (-1,1) g
                                        in  Just ([a*x],(i+1,g')))
            (1,mkStdGen sd)
  tn = timeSample r d
  cs = chunksFromList tn $ cycle xs

-- | A randomly generated sound (mono). Different seeds will generate
--   different sounds.
--
--   It is used to create 'karplus' waves.
noise :: Time   -- ^ Duration (0~)
      -> Double -- ^ Amplitude (0~1)
      -> Time   -- ^ Frequency (Hz)
      -> Int    -- ^ Random seed
      -> Sound
noise = noiseR 44100

-- | Like 'karplus', but allows you choose a custom sample rate.
karplusR :: Word32 -- ^ Sample rate
         -> Time   -- ^ Duration (0~)
         -> Double -- ^ Amplitude (0~1)
         -> Time   -- ^ Frequency (Hz)
         -> Double -- ^ Decay (0~1)
         -> Int    -- ^ Random seed
         -> Sound
{-# INLINE karplusR #-}
karplusR r d a f dc = velocity (dc**) . noiseR r d a f

-- | String-like sound based on randomly generated signals (see 'noise').
karplus :: Time   -- ^ Duration (0~)
        -> Double -- ^ Amplitude (0~1)
        -> Time   -- ^ Frequency (Hz)
        -> Double -- ^ Decay (0~1)
        -> Int    -- ^ Random seed
        -> Sound
{-# INLINE karplus #-}
karplus = karplusR 44100