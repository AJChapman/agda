{-# OPTIONS -fglasgow-exts -cpp #-}

{-| The parser doesn't know about operators and parses everything as normal
    function application. This module contains the functions that parses the
    operators properly. For a stand-alone implementation of this see
    @src\/prototyping\/mixfix@.

    It also contains the function that puts parenthesis back given the
    precedence of the context.
-}
module Syntax.Concrete.Operators
    ( OperatorException(..)
    , parseApplication
    , parseLHS
    , paren
    , mparen
    ) where

import Prelude hiding (putStrLn, print, putStr)
import Utils.IO

import Control.Monad.Trans
import Control.Exception
import Data.Typeable
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.List

import Syntax.Concrete.Pretty ()
import Syntax.Common
import Syntax.Concrete
import Syntax.Concrete.Operators.Parser
import Syntax.Position
import Syntax.Fixity
import Syntax.Scope

import Utils.ReadP
import Utils.Monad

#include "../../undefined.h"

---------------------------------------------------------------------------
-- * Exceptions
---------------------------------------------------------------------------

-- | Thrown by 'parseApplication' if the correct bracketing cannot be deduced.
data OperatorException
	= NoParseForApplication [Expr]
	| AmbiguousParseForApplication [Expr] [Expr]
	| NoParseForLHS Pattern
	| AmbiguousParseForLHS Pattern [Pattern]
    deriving (Typeable, Show)

instance HasRange OperatorException where
    getRange (NoParseForApplication es)		 = getRange es
    getRange (AmbiguousParseForApplication es _) = getRange es
    getRange (NoParseForLHS es)			 = getRange es
    getRange (AmbiguousParseForLHS es _)	 = getRange es

---------------------------------------------------------------------------
-- * Building the parser
---------------------------------------------------------------------------

getDefinedNames :: [KindOfName] -> ScopeM [(Name, Fixity)]
getDefinedNames kinds = do
    scope <- getScopeInfo
    let public  = publicNameSpace scope
	private = privateNameSpace scope
	defs	= concatMap (Map.assocs . definedNames) [public, private]
    return [ (x, fixity def) | (x, def) <- defs, kindOfName def `elem` kinds ]

localNames :: ScopeM ([Name], [(Name, Fixity)])
localNames = do
    scope <- getScopeInfo
    let public  = publicNameSpace scope
	private = privateNameSpace scope
	local	= localVariables scope
	(names, ops) = split $ localOps local ++ concatMap namespaceOps [public, private]
    return (names, ops)
    where
	namespaceOps = map operator . Map.assocs . definedNames
	localOps     = map localOp . Map.keys
	localOp x    = (x, defaultFixity)
	operator (x,def) = (x, fixity def)

	split ops = ([ x | Left x <- zs], [ y | Right y <- zs ])
	    where
		zs = concatMap opOrNot ops

	opOrNot (x@(Name _ [_]), fx) = [Left x]
	opOrNot (x, fx)		     = [Left x, Right (x, fx)]

data UseBoundNames = UseBoundNames | DontUseBoundNames

{-| Builds parser for operator applications from all the operators and function
    symbols in scope. When parsing a pattern we 'DontUseBoundNames' since a
    pattern binds new variables, but when parsing an expression we
    'UseBoundNames' and refute application of things that aren't in scope. The
    reason for this is to disambiguate things like @x + y@. This could mean
    both @_+_@ applied to @x@ and @y@, and @x@ applied to @+@ and @y@, but if there
    is no @+@ in scope it could only be the first.

    To avoid problems with operators of the same precedence but different
    associativity we decide (completely arbitrary) to fix the precedences of
    operators with the same given precedence in the following order (from
    loosest to hardest):

    - non-associative

    - left associative

    - right associative

    - prefix

    - postfix

    This has the effect that if you mix operators with the same precedence but
    different associativity the parser won't complain. One could argue that
    this is a Bad Thing, but since it's not trivial to implement the check it
    will stay this way until people start complaining about it.

    TODO: Clean up (too many fst and snd)
-}
buildParser :: IsExpr e => Range -> UseBoundNames -> ScopeM (ReadP e e)
buildParser r use = do
    (names, ops) <- localNames
    cons	 <- getDefinedNames [ConName]
    let conparts   = Set.fromList $ concatMap (parts . fst) cons
	connames   = Set.fromList $ map fst cons
	(non, fix) = partition nonfix ops
	set	   = Set.fromList names
	isLocal    = case use of
	    UseBoundNames     -> \x -> Set.member x set
	    DontUseBoundNames -> \x -> Set.member x connames || not (Set.member x conparts)
    return $ recursive $ \p ->
	concatMap (mkP p) (order fix)
	++ [ appP p ]
	++ map (nonfixP . opP p . fst) non
	++ [ const $ atomP isLocal ]
    where
	parts (Name _ [_]) = []
	parts (Name _ xs ) = [ Name noRange [Id s] | Id s <- xs ]

	level = fixityLevel . snd

	isinfixl (op, LeftAssoc _ _)  = isInfix op
	isinfixl _		      = False

	isinfixr (op, RightAssoc _ _) = isInfix op
	isinfixr _		      = False

	isinfix (op, NonAssoc _ _)    = isInfix op
	isinfix _		      = False

	on f g x y = f (g x) (g y)

	nonfix = isNonfix . fst
	order = groupBy ((==) `on` level) . sortBy (compare `on` level)

	mkP p0 ops = case concat [infx, inlfx, inrfx, prefx, postfx] of
	    []	    -> [id]
	    fs	    -> fs
	    where
		choice' = foldr1 (++++)
		f ++++ g = \p -> f p +++ g p
		inlfx	= fixP infixlP  isinfixl
		inrfx	= fixP infixrP  isinfixr
		infx	= fixP infixP   isinfix
		prefx	= fixP prefixP  (isPrefix . fst)
		postfx	= fixP postfixP (isPostfix . fst)

		fixP f g =
		    case filter g ops of
			[]  -> []
			ops -> [ f $ choice $ map (opP p0 . fst) ops ]

---------------------------------------------------------------------------
-- * Expression instances
---------------------------------------------------------------------------

instance IsExpr Expr where
    exprView e = case e of
	Ident (QName x)	-> LocalV x
	App _ e1 e2	-> AppV e1 e2
	OpApp r d es	-> OpAppV r d es
	HiddenArg _ e	-> HiddenArgV e
	_		-> OtherV e
    unExprView e = case e of
	LocalV x      -> Ident (QName x)
	AppV e1 e2    -> App (fuseRange e1 e2) e1 e2
	OpAppV r d es -> OpApp r d es
	HiddenArgV e  -> HiddenArg (getRange e) e
	OtherV e      -> e

instance IsExpr Pattern where
    exprView e = case e of
	IdentP (QName x) -> LocalV x
	AppP e1 e2	 -> AppV e1 e2
	OpAppP r d es	 -> OpAppV r d es
	HiddenP _ e	 -> HiddenArgV e
	_		 -> OtherV e
    unExprView e = case e of
	LocalV x	 -> IdentP (QName x)
	AppV e1 e2	 -> AppP e1 e2
	OpAppV r d es	 -> OpAppP r d es
	HiddenArgV e	 -> HiddenP (getRange e) e
	OtherV e	 -> e

---------------------------------------------------------------------------
-- * Parse functions
---------------------------------------------------------------------------

-- | Returns the list of possible parses.
parsePattern :: ReadP Pattern Pattern -> Pattern -> [Pattern]
parsePattern prs p = case p of
    AppP p (Arg h q) -> AppP <$> parsePattern prs p <*> (Arg h <$> parsePattern prs q)
    RawAppP _ ps     -> parsePattern prs =<< parse prs ps
    OpAppP r d ps    -> OpAppP r d <$> mapM (parsePattern prs) ps
    HiddenP _ _	     -> fail "bad hidden argument"
    AsP r x p	     -> AsP r x <$> parsePattern prs p
    ParenP r p	     -> ParenP r <$> parsePattern prs p
    WildP _	     -> return p
    AbsurdP _	     -> return p
    LitP _	     -> return p
    IdentP _	     -> return p


-- | Parses a left-hand side, and makes sure that it defined the expected name.
--   TODO: check the arities of constructors. There is a possible ambiguity with
--   postfix constructors:
--	Assume _ * is a constructor. Then 'true *' can be parsed as either the
--	intended _* applied to true, or as true applied to a variable *. If we
--	check arities this problem won't appear.
parseLHS :: Name -> Pattern -> ScopeM Pattern
parseLHS top p = do
    patP <- buildParser (getRange p) DontUseBoundNames
    cons <- getNames [ConName]
    case filter (validPattern top cons) $ parsePattern patP p of
	[p] -> return p
	[]  -> throwDyn $ NoParseForLHS p
	ps  -> throwDyn $ AmbiguousParseForLHS p ps
    where
	getNames kinds = map fst <$> getDefinedNames kinds

	validPattern :: Name -> [Name] -> Pattern -> Bool
	validPattern top cons p = case appView p of
	    IdentP (QName x) : ps -> x == top && all (validPat cons) ps
	    _			  -> False

	validPat :: [Name] -> Pattern -> Bool
	validPat cons p = case appView p of
	    [_]			  -> True
	    IdentP (QName x) : ps -> elem x cons && all (validPat cons) ps
	    ps			  -> all (validPat cons) ps

	appView :: Pattern -> [Pattern]
	appView p = case p of
	    AppP p (Arg _ q) -> appView p ++ [q]
	    OpAppP _ op ps   -> IdentP (QName op) : ps
	    ParenP _ p	     -> appView p
	    RawAppP _ _	     -> __IMPOSSIBLE__
	    HiddenP _ _	     -> __IMPOSSIBLE__
	    _		     -> [p]

parseApplication :: [Expr] -> ScopeM Expr
parseApplication [e] = return e
parseApplication es = do
    p <- buildParser (getRange es) UseBoundNames
    case parse p es of
	[e] -> return e
	[]  -> throwDyn $ NoParseForApplication es
	es' -> throwDyn $ AmbiguousParseForApplication es es'

-- Inserting parenthesis --------------------------------------------------

paren :: (Name -> Fixity) -> Expr -> Precedence -> Expr
paren _   e@(App _ _ _)	       p = mparen (appBrackets p) e
paren f	  e@(OpApp _ op _)     p = mparen (opBrackets (f op) p) e
paren _   e@(Lam _ _ _)	       p = mparen (lamBrackets p) e
paren _   e@(Fun _ _ _)	       p = mparen (lamBrackets p) e
paren _   e@(Pi _ _)	       p = mparen (lamBrackets p) e
paren _   e@(Let _ _ _)	       p = mparen (lamBrackets p) e
paren _	  e@(Ident _)	       p = e
paren _	  e@(Lit _)	       p = e
paren _	  e@(QuestionMark _ _) p = e
paren _	  e@(Underscore _ _)   p = e
paren _	  e@(Set _)	       p = e
paren _	  e@(SetN _ _)	       p = e
paren _	  e@(Prop _)	       p = e
paren _	  e@(Paren _ _)	       p = e
paren _	  e@(As _ _ _)	       p = e
paren _	  e@(Absurd _)	       p = e
paren _	  e@(RawApp _ _)       p = __IMPOSSIBLE__
paren _	  e@(HiddenArg _ _)    p = __IMPOSSIBLE__

mparen :: Bool -> Expr -> Expr
mparen True  e = Paren (getRange e) e
mparen False e = e

