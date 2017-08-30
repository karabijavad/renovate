module Renovate.BasicBlock.Types (
  BasicBlock(..),
  ConcreteBlock,
  SymbolicBlock,
  SymbolicInfo(..),
  TaggedInstruction,
  tag,
  tagInstruction,
  hasNoSymbolicTarget,
  symbolicTarget,
  projectInstruction
  ) where

import Data.Maybe ( isNothing )
import Renovate.Address

-- | A basic block is a list of instructions (whose sizes and specific
-- information we can find from the ISA).  Basic blocks also have a
-- starting address, which is polymorphic.
--
-- The intent is that basic blocks can have either concrete or
-- symbolic addresses (instantiated as 'ConcreteBlock' and
-- 'SymbolicBlock', respectively)
data BasicBlock addr i a =
  BasicBlock { basicBlockInstructions :: [i a]
             , basicBlockAddress :: addr
             }
  deriving (Eq, Show)


-- | The type of concrete 'BasicBlock's that have been assigned real
-- addresses.
--
-- Note that we use 'MC.MemWord' for the address of blocks rather than
-- 'MC.SegmentedAddr', as we need to create blocks that haven't yet
-- been assigned to a segment, so we can't actually give them a
-- 'MC.SegmentedAddr' (there is no segment for them to refer to).
type ConcreteBlock i w = BasicBlock (RelAddress w) i ()

-- | A wrapper around a normal instruction that includes an optional
-- 'SymbolicAddress'.
--
-- When we start relocating code, we need to track the targets of
-- jumps *symbolically* (i.e., not based on concrete address target).
-- That allows us to stitch the jumps in the instrumented blocks
-- together.  This wrapper holds the symbolic address.
--
-- Note: this representation isn't good for instructions with more
-- than one possible target (if there is such a thing).  If that
-- becomes an issue, the annotation will need to sink into the operand
-- annotations, and we'll need a helper to collect those.
newtype TaggedInstruction i a = Tag { unTag :: (i a, Maybe SymbolicAddress) }

-- | Annotate an instruction with a symbolic target.
--
-- We use this if the instruction is a jump and we will need to
-- relocate it, so we need to know the symbolic block it is jumping
-- to.
tagInstruction :: Maybe SymbolicAddress -> i a -> TaggedInstruction i a
tagInstruction ma i = Tag (i, ma)

-- | Return 'True' if the 'TaggedInstruction' has no symbolic target.
hasNoSymbolicTarget :: TaggedInstruction i a -> Bool
hasNoSymbolicTarget = isNothing . symbolicTarget

-- | If the 'TaggedInstruction' has a 'SymbolicAddress' as a target,
-- return it.
symbolicTarget :: TaggedInstruction i a -> Maybe SymbolicAddress
symbolicTarget = snd . unTag

-- | Remove the tag from an instruction
projectInstruction :: TaggedInstruction i a -> i a
projectInstruction = fst . unTag

-- | Tag an instruction with a 'SymbolicAddress' target
tag :: i a -> Maybe SymbolicAddress -> TaggedInstruction i a
tag i msa = Tag (i, msa)

-- | The type of 'BasicBlock's that only have symbolic addresses.
-- Their jumps are annotated with symbolic address targets as well,
-- which refer to other 'SymbolicBlock's.
type SymbolicBlock i a w = BasicBlock (SymbolicInfo w) (TaggedInstruction i) a

-- | Address information for a symbolic block.
--
-- This includes a symbolic address that uniquely and symbolically
-- identifies the block.  It also includes the original concrete
-- address of the corresponding 'ConcreteBlock' for this symbolic
-- block.
data SymbolicInfo w = SymbolicInfo { symbolicAddress :: SymbolicAddress
                                   , concreteAddress :: RelAddress w
                                   }
                    deriving (Eq, Ord, Show)

