-- | Low-level code redirection helpers
--
-- This module is only exposed for testing purposes and is not an
-- external API.
module Renovate.Redirect.Internal ( redirectOriginalBlocks ) where

import           Data.Monoid
import qualified Data.Traversable as T

import           Prelude

import           Renovate.BasicBlock
import           Renovate.ISA
import           Renovate.Redirect.Monad

-- | Overwrite the entry points of each original block with a pointer
-- to the instrumented block, if possible.
--
-- It may not be possible if the original block is shorter than ~7
-- bytes.  We can improve this later, but for now, we will miss some
-- blocks.  We will generate a diagnostic for each one.
--
-- This is a low level helper mostly exposed for testing
redirectOriginalBlocks :: (Monad m, T.Traversable t, InstructionConstraints i a)
                       => t (ConcreteBlock i w, ConcreteBlock i w)
                       -> RewriterT i a w m (t (ConcreteBlock i w, ConcreteBlock i w))
redirectOriginalBlocks = T.traverse redirectBlock

-- | Given an original 'ConcreteBlock' and an instrumented
-- 'ConcreteBlock', rewrite the original block to redirect to the
-- instrumented version, if possible.
--
-- This function will generate diagnostics for blocks that cannot be
-- redirected.
--
-- Note that the address of the jump instruction is the address of the
-- original block (since it will be the first instruction).
redirectBlock :: (Monad m, InstructionConstraints i a)
              => (ConcreteBlock i w, ConcreteBlock i w)
              -> RewriterT i a w m (ConcreteBlock i w, ConcreteBlock i w)
redirectBlock unmodified@(origBlock, instrBlock) = do
  isa <- askISA
  let origBlockSize = concreteBlockSize isa origBlock
      jmpInsns = isaMakeRelativeJumpTo isa (basicBlockAddress origBlock) (basicBlockAddress instrBlock)
      jmpSize = instructionStreamSize isa jmpInsns
  case origBlockSize < jmpSize of
    True -> do
      logDiagnostic $ BlockTooSmallForRedirection origBlockSize jmpSize (basicBlockAddress origBlock)
                        (show origBlock ++ " |-> " ++ show instrBlock)
      return unmodified
    False -> do
      let padding = isaMakePadding isa (origBlockSize - jmpSize)
          origBlock' = origBlock { basicBlockInstructions = jmpInsns <> padding }
      return (origBlock', instrBlock)

