{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
module Renovate.Redirect.LayoutBlocks.Compact (
  Layout(..),
  compactLayout
  ) where

import qualified GHC.Err.Located as L

import qualified Data.ByteString as BS
import           Data.Maybe ( catMaybes )
import           Data.Ord ( Down(..) )
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import           Control.Exception ( assert )
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.ST
import qualified Data.Foldable as F
import qualified Data.Functor.Compose as C
import qualified Data.Heap as H
import qualified Data.List as L
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import           Data.STRef
import qualified Data.Traversable as T
import qualified Data.UnionFind.ST as UF
import           Data.Word ( Word64 )
import           Text.Printf ( printf )

import qualified System.Random.MWC as MWC

import qualified Data.Macaw.CFG as MM
import           Data.Parameterized.Some ( Some(Some) )
import qualified Lang.Crucible.Analysis.Fixpoint.Components as WTO
import qualified Lang.Crucible.CFG.Core as CFG
import qualified What4.ProgramLoc as W4

import           Renovate.Address
import           Renovate.BasicBlock
import           Renovate.ISA
import           Renovate.Recovery ( SCFG, SymbolicCFG, getSymbolicCFG )
import           Renovate.Redirect.Monad

import           Renovate.Redirect.LayoutBlocks.Types

-- | The address heap associates chunks of memory to addresses.  The
-- ordering of the heap is based on the size of the chunk of memory at
-- each address. It's a priority heap with larger addresses having
-- higher priority, hence @Down Int@ to sort decreasing on @Int@ size.
type AddressHeap arch = H.Heap (H.Entry (Down Int) (ConcreteAddress arch))

-- | Compute a concrete address for each 'SymbolicBlock'.
--
-- Right now, we use an inefficient encoding of jumps.  We could do
-- better later on.
compactLayout :: forall m t arch
              .  (MonadIO m, T.Traversable t, InstructionConstraints arch)
              => ConcreteAddress arch
              -- ^ Address to begin block layout of instrumented blocks
              -> LayoutStrategy
              -> t (SymbolicPair arch)
              -> t (SymbolicAddress arch, BS.ByteString)
              -> M.Map (ConcreteAddress arch) (SymbolicCFG arch)
              -> RewriterT arch m (Layout AddressAssignedPair arch)
compactLayout startAddr strat blocks injectedCode cfgs_ = do
  h0 <- case strat of
    -- the parallel strategy is now a special case of compact. In particular,
    -- we avoid allocating the heap and we avoid sorting the input blocklist.
    Parallel _ -> return mempty
    _ -> buildAddressHeap startAddr blocks

  -- Only materialize the CFGs if we absolutely have to.
  let keepLoops :: Bool
      keepLoops = loopStrategy strat == KeepLoopBlocksTogether
  cfgs <- if keepLoops then traverse (liftIO . getSymbolicCFG) cfgs_ else return M.empty

  -- We want to keep together blocks that are part of loops. Consequently we
  -- want a way to map each block that's part of a loop to a canonical
  -- representative block of that loop, and check properties of all the blocks
  -- with the same canonical representative. First we build the mapping.
  --
  -- We won't rule out the possibility that some block is part of multiple
  -- loops yet, though that seems pretty preposterous to me (dmwit) right now.
  let repMap :: M.Map (ConcreteAddress arch) (ConcreteAddress arch)
      repMap = cfgHeads cfgs

  -- Which loops (as represented by their canonical block) contain blocks which
  -- have been modified?
      modifiedLoops :: S.Set (ConcreteAddress arch)
      modifiedLoops = S.fromList . catMaybes $
        [ M.lookup (basicBlockAddress (lpOrig b)) repMap
        | SymbolicPair b <- F.toList blocks
        , lpStatus b == Modified
        ]

      isPartOfModifiedLoop :: LayoutPair a arch -> Bool
      isPartOfModifiedLoop b = case M.lookup (basicBlockAddress (lpOrig b)) repMap of
        Just rep -> rep `S.member` modifiedLoops
        Nothing -> False

  -- Augment all symbolic blocks such that fallthrough behavior is explicitly
  -- represented with symbolic unconditional jumps.
  --
  -- We need this so that we can re-arrange them and preserve the fallthrough
  -- behavior of blocks ending in conditional jumps (or non-jumps).
  -- traceM (show (PD.vcat (map PD.pretty (L.sortOn (basicBlockAddress . lpOrig) (F.toList blocks)))))
  mem     <- askMem
  let (modifiedBlocks, unmodifiedBlocks) = L.partition
        (\(SymbolicPair b) -> lpStatus b == Modified || (keepLoops && isPartOfModifiedLoop b))
        (F.toList blocks)
  blocks' <- reifyFallthroughSuccessors mem modifiedBlocks blocks

  -- Either, a) Sort all of the instrumented blocks by size
  --         b) Randomize the order of the blocks.
  --         c) Use the input order exactly
  -- The (a) will give a more optimal answer, but (b) will provide some
  -- synthetic diversity at the cost of optimality. (c) is for treating
  -- the parallel layout as a special case of compact.
  isa <- askISA

  let newBlocksList = F.toList ((lpNew . unSymbolicPair) <$> blocks')
      newBlocksMap = groupByRep repMap blocks'
      newBlocks | keepLoops = M.elems newBlocksMap
                | otherwise = map (:[]) newBlocksList

  let sortedBlocks = case strat of
        Compact SortedOrder        _ -> L.sortOn    (bySize isa mem) newBlocks
        Compact (RandomOrder seed) _ -> randomOrder seed             newBlocks
        Parallel                   _ -> newBlocks

  -- Allocate an address for each block (falling back to startAddr if the heap
  -- can't provide a large enough space).
  (h1, symBlockAddrs, injectedAddrs) <- allocateSymbolicBlockAddresses startAddr h0 sortedBlocks injectedCode

  -- Overwrite any leftover space with ISA-specific padding. This is not,
  -- strictly speaking, necessary; without it, the assembler will take bytes
  -- from the original text section as padding instead. But it is safer to
  -- catch jumps that our tool didn't know about by landing at a halt
  -- instruction, when that is possible.
  h2 <- case strat of
    -- In the parallel layout, we don't use any space reclaimed by redirecting
    -- things, so we should overwrite it all with padding.
    Parallel{} -> buildAddressHeap startAddr blocks
    _ -> return h1

  let paddingBlocks :: [ConcreteBlock arch]
      paddingBlocks = [ BasicBlock (isaMakePadding isa (fromIntegral size)) addr
                      | H.Entry (Down size) addr <- H.toUnsortedList h2
                      ]

  -- Traverse the original container and update it with the addresses allocated
  -- to each symbolic block.  This will have an irrefutable pattern match that
  -- is actually safe.
  --
  -- Note that we are assigning addresses to blocks', which has augmented the
  -- symbolic blocks with additional jumps to preserve fallthrough behavior.
  -- That is critical.
  assignedPairs <- T.traverse (assignConcreteAddress symBlockAddrs) (F.toList blocks' ++ unmodifiedBlocks)

  return Layout { programBlockLayout = assignedPairs
                , layoutPaddingBlocks = paddingBlocks
                , injectedBlockLayout = [ (symAddr, caddr, bs) | (caddr, (symAddr, bs)) <- M.elems injectedAddrs ]
                }
  where
    bySize isa mem = Down . sum . map (symbolicBlockSize isa mem startAddr)

-- | Group together blocks that are part of a loop. The arguments are a map
-- that tells which loop each block is part of, and a collection of blocks to
-- partition. The returned result is a partitioning of the input collection of
-- blocks.
--
-- Eventually we're going to layout the blocks in each sublist of the
-- partition. If the original (un-rewritten) loop was created in a way that
-- took advantage of instruction cache locality, we'd like to preserve that
-- property. Therefore we sort each sublist of the partition by its original
-- memory location, so that blocks within a single loop that were previously
-- adjacent are kept adjacent after layout.
groupByRep ::
  Foldable t =>
  M.Map (ConcreteAddress arch) (ConcreteAddress arch) ->
  t (SymbolicPair arch) ->
  M.Map (ConcreteAddress arch) [SymbolicBlock arch]
groupByRep repMap blocks = id
  . map lpNew
  . L.sortOn (basicBlockAddress . lpOrig)
  <$> M.fromListWith (++)
      [ (rep, [b])
      | SymbolicPair b <- F.toList blocks
      , let addr = basicBlockAddress (lpOrig b)
            rep = M.findWithDefault addr addr repMap
      ]

cfgHeads :: forall arch pairs.
  ( pairs ~ [(ConcreteAddress arch, ConcreteAddress arch)]
  , MM.MemWidth (MM.ArchAddrWidth arch)
  ) =>
  M.Map (ConcreteAddress arch) (SCFG CFG.SomeCFG arch) ->
  M.Map (ConcreteAddress arch) (ConcreteAddress arch)
cfgHeads cfgs = runST $ do
  rel <- discrete
  F.traverse_ (uncurry (equate rel)) (goSCFGs cfgs)
  freeze rel
  where
  goSCFGs :: M.Map (ConcreteAddress arch) (SCFG CFG.SomeCFG arch) -> pairs
  goSCFGs = F.foldMap goSCFG

  goSCFG :: SCFG CFG.SomeCFG arch -> pairs
  goSCFG (CFG.SomeCFG cfg) = foldMap
    (goWTOComponent (CFG.cfgBlockMap cfg))
    (WTO.cfgWeakTopologicalOrdering cfg)

  goWTOComponent :: CFG.BlockMap ext blocks ret -> WTO.WTOComponent (Some (CFG.BlockID blocks)) -> pairs
  goWTOComponent _ WTO.Vertex{} = []
  goWTOComponent m component =
    [ (src, tgt)
    | tgt <- goSomeBlockID m (WTO.wtoHead component)
    , node <- F.toList component
    , src <- goSomeBlockID m node
    ]

  goSomeBlockID :: CFG.BlockMap ext blocks ret -> Some (CFG.BlockID blocks) -> [ConcreteAddress arch]
  goSomeBlockID m (Some ix) = goPosition . W4.plSourceLoc . CFG.blockLoc . CFG.getBlock ix $ m

  goPosition :: W4.Position -> [ConcreteAddress arch]
  goPosition (W4.BinaryPos _ w) = [concreteFromAbsolute (MM.memWord w)]
  goPosition _ = []

-- | A mutable equivalence relation; it can be mutated by making the relation
-- coarser, equating two previously-inequal things.
type EquivRel s a = STRef s (M.Map a (UF.Point s a))

-- | The finest equivalence relation: nothing is related to anything else.
discrete :: ST s (EquivRel s a)
discrete = newSTRef M.empty

-- | Modify the given equivalence relation by equating two values.
equate :: Ord a => EquivRel s a -> a -> a -> ST s ()
equate ref l r = do
  m0 <- readSTRef ref
  (pl, m1) <- insertLookupA l (UF.fresh l) m0
  (pr, m2) <- insertLookupA r (UF.fresh r) m1
  UF.union pl pr
  writeSTRef ref m2

-- | Produce an immutable representation of an equivalence relation. The
-- resulting 'Map' gives a mapping from a member of an equivalence class to a
-- canonical representative of that class (and all members of the class map to
-- the same representative). It is unspecified how the representative is chosen
-- from among equivalence class members. Missing keys in the 'Map' are
-- equivalent only to themselves.
freeze :: EquivRel s a -> ST s (M.Map a a)
freeze = readSTRef >=> traverse UF.descriptor

-- | Look up a key in a 'Map'. If the key doesn't exist in the 'Map' yet,
-- insert the result of running the given action first, and then do the lookup.
insertLookupA :: (Applicative f, Ord k) => k -> f v -> M.Map k v -> f (v, M.Map k v)
insertLookupA k fv m = C.getCompose (M.alterF (pairSelf . maybe fv pure) k m) where
  pairSelf = C.Compose . fmap (\self -> (self, Just self))

-- | Look up the concrete address assigned to each symbolic block and tag it
-- onto the tuple to create a suitable return value.
--
-- Every symbolic block is assumed to have been assigned an address at this
-- point.
assignConcreteAddress :: (Monad m, MM.MemWidth (MM.ArchAddrWidth arch))
                      => M.Map (SymbolicInfo arch) (ConcreteAddress arch)
                      -> SymbolicPair arch
                      -> RewriterT arch m (AddressAssignedPair arch)
assignConcreteAddress assignedAddrs (SymbolicPair (LayoutPair cb sb Modified)) = do
  case M.lookup (basicBlockAddress sb) assignedAddrs of
    Nothing -> L.error $ printf "Expected an assigned address for symbolic block %s (derived from concrete block %s)"
                                (show (basicBlockAddress sb))
                                (show (basicBlockAddress cb))
    Just addr -> return (AddressAssignedPair (LayoutPair cb (AddressAssignedBlock sb addr) Modified))
assignConcreteAddress _ (SymbolicPair (LayoutPair cb sb Unmodified)) =
  return (AddressAssignedPair (LayoutPair cb (AddressAssignedBlock sb (basicBlockAddress cb)) Unmodified))

allocateSymbolicBlockAddresses :: (Monad m, MM.MemWidth (MM.ArchAddrWidth arch), F.Foldable t, Functor t)
                               => ConcreteAddress arch
                               -> AddressHeap arch
                               -> [[SymbolicBlock arch]]
                               -> t (SymbolicAddress arch, BS.ByteString)
                               -> RewriterT arch m ( AddressHeap arch
                                                   , M.Map (SymbolicInfo arch) (ConcreteAddress arch)
                                                   , M.Map (SymbolicAddress arch) (ConcreteAddress arch, (SymbolicAddress arch, BS.ByteString))
                                                   )
allocateSymbolicBlockAddresses startAddr h0 blocksBySize injectedCode = do
  isa <- askISA
  mem <- askMem
  let blockItemSize = symbolicBlockSize isa mem startAddr
  let blockItemKey = basicBlockAddress
  (nextStart, h1, m1) <- F.foldlM (allocateBlockGroupAddresses blockItemSize blockItemKey const) (startAddr, h0, M.empty) blocksBySize
  (_, h2, m2) <- F.foldlM (allocateBlockGroupAddresses (fromIntegral . BS.length . snd) fst (,)) (nextStart, h1, M.empty) ((:[]) <$> injectedCode)
  return (h2, m1, m2)

-- | Allocate an address for the given symbolic block.
--
-- If the block will fit into a space held in the address heap, allocate it to
-- that space (and return unused space to the heap).  Otherwise, place the
-- symbolic block into the new code section we are building up (based on the
-- @newTextAddr@).
--
-- Note that the 'SymbolicBlock' at this stage must have been augmented with its
-- final unconditional jump to preserve fallthrough control flow (we rely on the
-- size of the block to be correct).
--
-- NOTE: This function is excessively parameterized so that we can assign
-- addresses both to lists of concrete blocks and also injected code (which is
-- just a bytestring instead of a basic block).
allocateBlockGroupAddresses
                     :: (MM.MemWidth (MM.ArchAddrWidth arch), Monad m, Ord key)
                     => (item -> Word64)
                     -> (item -> key)
                     -> (ConcreteAddress arch -> item -> val)
                     -> (ConcreteAddress arch, AddressHeap arch, M.Map key val)
                     -> [item]
                     -> RewriterT arch m (ConcreteAddress arch, AddressHeap arch, M.Map key val)
allocateBlockGroupAddresses itemSize itemKey itemVal (newTextAddr, h, m) items =
  case H.viewMin h of
    Nothing -> return allocateNewTextAddr
    Just (H.Entry (Down size) addr, h')
      | size < fromIntegral itemsSize -> return allocateNewTextAddr
      | otherwise -> do
          recordReusedBytes size
          return (allocateFromHeap size addr h')
  where
    addOff = addressAddOffset

    itemsSizes = map itemSize items
    itemsSize = sum itemsSizes

    blockGroupMapping baseAddr =
      let addrs = scanl (\addr size -> addr `addOff` fromIntegral size) baseAddr itemsSizes
          newMappings = zipWith (\addr item -> (itemKey item, itemVal addr item)) addrs items
      in M.union m (M.fromList newMappings)

    allocateNewTextAddr =
      let nextBlockStart = newTextAddr `addOff` fromIntegral itemsSize
      in (nextBlockStart, h, blockGroupMapping newTextAddr)

    allocateFromHeap allocSize addr h' =
      assert (allocSize >= fromIntegral itemsSize) $ do
        let addr'      = addr `addOff` fromIntegral itemsSize
            allocSize' = allocSize - fromIntegral itemsSize
        case allocSize' of
          0 -> (newTextAddr, h', blockGroupMapping addr)
          _ ->
            let h'' = H.insert (H.Entry (Down allocSize') addr') h'
            in (newTextAddr, h'', blockGroupMapping addr)


-- | Make the fallthrough behavior of our symbolic blocks explicit.
--
-- During the layout process, we are going to re-arrange blocks so that old
-- fallthrough behavior no longer works.  We make fallthroughs explicit (with
-- unconditional jumps).
--
-- A block has fallthrough behavior if it does not end in an unconditional jump.
reifyFallthroughSuccessors :: (Traversable t, Monad m, MM.MemWidth (MM.ArchAddrWidth arch), Traversable t')
                           => MM.Memory (MM.ArchAddrWidth arch)
                           -> t (SymbolicPair arch)
                           -- ^ The modified blocks
                           -> t' (SymbolicPair arch)
                           -- ^ All blocks (which we need to compute the fallthrough address index)
                           -> RewriterT arch m (t (SymbolicPair arch))
reifyFallthroughSuccessors mem modifiedBlocks allBlocks =
  T.traverse (addExplicitFallthrough mem symSuccIdx) modifiedBlocks
  where
    blist0 = F.toList (fmap (lpNew . unSymbolicPair) allBlocks)
    symSuccs | length blist0 > 1 = zip blist0 (tail blist0)
             | otherwise = []
    -- An index mapping the symbolic address of a symbolic basic block to the
    -- symbolic address of its successor (in program order).
    symSuccIdx = F.foldl' indexSymbolicSuccessors M.empty symSuccs
    indexSymbolicSuccessors m (symBlock, symSucc) =
      M.insert (basicBlockAddress symBlock) (basicBlockAddress symSucc) m

type SuccessorMap arch = M.Map (SymbolicInfo arch) (SymbolicInfo arch)

addExplicitFallthrough :: (Monad m, MM.MemWidth (MM.ArchAddrWidth arch))
                       => MM.Memory (MM.ArchAddrWidth arch)
                       -> SuccessorMap arch
                       -> SymbolicPair arch
                       -> RewriterT arch m (SymbolicPair arch)
addExplicitFallthrough mem symSucIdx pair@(SymbolicPair (LayoutPair cb sb Modified)) = do
  isa <- askISA
  -- We pass in a fake relative address since we don't need the resolution of
  -- relative jumps.  We just need the type of jump.
  --
  -- If the block ends in an unconditional jump, just return it unmodified.
  -- Otherwise, append an absolute jump to the correct location.
  let newPair = SymbolicPair (LayoutPair cb (appendUnconditionalJump isa symSucIdx cb sb) Modified)
  case isaJumpType isa lastInsn mem fakeAddress of
    br | isUnconditionalJT br -> return pair
       | otherwise            -> return newPair
  where
    -- We explicitly match on all constructor patterns so that if/when new ones
    -- are added this will break instead of having some default case that does
    -- (potentially) the wrong thing on the new cases.
    isUnconditionalJT (Return       cond    ) = isUnconditionalCond cond
    isUnconditionalJT (IndirectJump cond    ) = isUnconditionalCond cond
    isUnconditionalJT (AbsoluteJump cond _  ) = isUnconditionalCond cond
    isUnconditionalJT (RelativeJump cond _ _) = isUnconditionalCond cond
    isUnconditionalJT (IndirectCall         ) = False
    isUnconditionalJT (DirectCall {}        ) = False
    isUnconditionalJT (NoJump               ) = False

    isUnconditionalCond Unconditional = True
    isUnconditionalCond Conditional   = False

    fakeAddress = concreteFromAbsolute 0
    lastInsn
      | null (basicBlockInstructions sb) = L.error (printf "Empty block for symbolic block %s (derived from block %s)"
                                                           (show (basicBlockAddress sb))
                                                           (show (basicBlockAddress cb)))
      | otherwise = projectInstruction $ last (basicBlockInstructions sb)
addExplicitFallthrough _ _ pair@(SymbolicPair (LayoutPair _ _ Unmodified)) = return pair

appendUnconditionalJump :: (MM.MemWidth (MM.ArchAddrWidth arch))
                        => ISA arch
                        -> SuccessorMap arch
                        -> ConcreteBlock arch
                        -> SymbolicBlock arch
                        -> SymbolicBlock arch
appendUnconditionalJump isa symSucIdx cb sb =
  case M.lookup (basicBlockAddress sb) symSucIdx of
    Nothing -> L.error (printf "Expected a successor block for symbolic block %s (derived from block %s)"
                               (show (basicBlockAddress sb))
                               (show (basicBlockAddress cb)))
    Just symSucc ->
      let insns = isaMakeSymbolicJump isa (symbolicAddress symSucc)
      in sb { basicBlockInstructions = basicBlockInstructions sb ++ insns }


buildAddressHeap :: (MM.MemWidth (MM.ArchAddrWidth arch), Foldable t, Monad m)
                 => ConcreteAddress arch
                 -> t (SymbolicPair arch)
                 -> RewriterT arch m (AddressHeap arch)
buildAddressHeap startAddr blocks = do
  isa <- askISA
  let dummyJump = isaMakeRelativeJumpTo  isa startAddr startAddr
      jumpSize = fromIntegral $ sum (map (isaInstructionSize isa) dummyJump)
  return $ F.foldl' (addOriginalBlock isa jumpSize) H.empty blocks

-- | Add the available space in a 'ConcreteBlock' to the heap
--
-- We subtract out the space required to redirect execution of the block to its
-- instrumented version.
--
-- NOTE: We only add blocks that have been *modified*.  If a block is
-- unmodified, overwriting it would throw away code, as we don't lay out
-- duplicates of unmodified blocks.
addOriginalBlock :: (MM.MemWidth (MM.ArchAddrWidth arch))
                 => ISA arch
                 -> Word64
                 -> AddressHeap arch
                 -> SymbolicPair arch
                 -> AddressHeap arch
addOriginalBlock isa jumpSize h (SymbolicPair (LayoutPair cb _ status))
  | bsize > jumpSize && status == Modified =
    H.insert (H.Entry (Down spaceSize) addr) h
  | otherwise = h
  where
    bsize     = concreteBlockSize isa cb
    spaceSize :: Int
    spaceSize = fromIntegral (bsize - jumpSize)
    addr      = basicBlockAddress cb `addressAddOffset` fromIntegral jumpSize

randomOrder :: RandomSeed -> [a] -> [a]
randomOrder seed initial = runST $ do
  gen      <- MWC.initialize seed
  vec      <- V.thaw (V.fromList initial)
  finalVec <- go gen 0 vec >>= V.freeze
  return (V.toList finalVec)
  where
  -- This looks like a bit of a mess, but it's actually just the fisher-yates
  -- inplace shuffle.
  go :: MWC.GenST s -> Int -> MV.STVector s a -> ST s (MV.STVector s a)
  go g i vec
    | i >= MV.length vec - 1 = return vec
    | otherwise = do
      j <- MWC.uniformR (i,MV.length vec-1) g
      MV.swap vec i j
      go g (i+1) vec

{- Note [Design]

The idea is that we want to re-use space in the original basic blocks to hold
new (instrumented) basic blocks.  We'll create a heap of all of the space
available in the original blocks and allocate that space to instrumented blocks.
Any instrumented blocks that cannot fit will be added to a new section.

Before we start, we need to augment each basic block that has a fallthrough case
with an unconditional jump to the correct block.  This means adding an
instruction to the end with a symbolic target.  We need to pre-process all
blocks to find fallthrough cases.

Steps:

1) Add all of the original basic blocks to the heap, subtracting the space
   required to add the redirection jump at the beginning.  If an original block
   is smaller than the size of a redirection jump, don't bother to add it.

2) Order the instrumented blocks by their size in bytes (with the largest blocks
   first).

3) Pull out the largest space available in the heap.  If it can fit the current
   instrumented block (plus space for an unconditional jump), allocate that
   address and return unused storage to the heap.



-}
