{
{-| The lexer is generated by Alex (<http://www.haskell.org/alex>) and is an
    adaptation of GHC's lexer. The main lexing function 'lexer' is called by
    the "Syntax.Parser.Parser" to get the next token from the input.
-}
module Syntax.Parser.Lexer
    ( -- * The main function
      lexer
      -- * Lex states
    , normal, literate
    , layout, empty_layout, bol, imp_dir
      -- * Alex generated functions
    , AlexReturn(..), alexScan
    ) where

import Data.List

import Syntax.Parser.Alex
import Syntax.Parser.Comments
import Syntax.Parser.Layout
import Syntax.Parser.LexActions
import Syntax.Parser.Monad
import Syntax.Parser.StringLiterals
import Syntax.Parser.Tokens
import Syntax.Literal

}

$digit	    = 0-9
$idstart    = [ A-Z a-z ]
$alphanum   = [ $idstart $digit ' ]
$sym	    = [ \!\#\$\%\&\*\+\.\/\<\=\>\@\\\^\|\~\: ]
$symstart   = [ \- $sym ]
$notdash    = [ ' $sym ]
$symbol	    = [ \- ' $sym ]

$white_nonl = $white # \n

@number	    = $digit+
@exponent   = [eE] [\-\+]? @number
@float	    = @number \. @number @exponent? | @number @exponent

@ident	    = $idstart $alphanum*
@operator   = $symstart $symbol*

@namespace  = (@ident \.)*
@q_ident    = @namespace @ident
@q_operator = @namespace @operator

tokens :-

-- Lexing literate files
<tex>	 ^ \\ "begin{code}" \n	{ begin_ code }
<tex>	 ^ .* \n		{ withRange $ TokTeX . snd }
<tex>	 ^ .+			{ withRange $ TokTeX . snd }
<code>   ^ \\ "end{code}" \n	{ end_ }

-- White space
<0,code,bol_,layout_,empty_layout_,imp_dir_>
    $white_nonl+    ;

-- Comments
<0,code,bol_,layout_,empty_layout_,imp_dir_>
    "{-"	    { nestedComment }

-- Dashes followed by an operator symbol should be parsed as an operator.
<0,code,bol_,layout_,empty_layout_,imp_dir_>   "--"\-* [^$symbol] .* ;
<0,code,bol_,layout_,empty_layout_,imp_dir_>   "--"\-* $		    ;

-- We need to check the offside rule for the first token on each line.  We
-- should not check the offside rule for the end of file token or an
-- '\end{code}'
<0,code> \n	{ begin bol_ }
<bol_>
    {
	\n		    ;
	^ \\ "end{code}"    { end }
	() / { notEOF }	    { offsideRule }
    }

-- After a layout keyword there is either an open brace (no layout) or the
-- indentation of the first token decides the column of the layout block.
<layout_>
    {	\n	;
	\{	{ endWith openBrace }
	()	{ endWith newLayoutContext }
    }

-- The only rule for the empty_layout state. Generates a close brace.
<empty_layout_> ()		{ emptyLayout }

-- Keywords
<0,code> let		{ keyword KwLet }
<0,code> in		{ keyword KwIn }
<0,code> where		{ keyword KwWhere }
<0,code> postulate	{ keyword KwPostulate }
<0,code> open		{ keyword KwOpen }
<0,code> import		{ keyword KwImport }
<0,code> module		{ keyword KwModule }
<0,code> data		{ keyword KwData }
<0,code> infix		{ keyword KwInfix }
<0,code> infixl		{ keyword KwInfixL }
<0,code> infixr		{ keyword KwInfixR }
<0,code> mutual		{ keyword KwMutual }
<0,code> abstract	{ keyword KwAbstract }
<0,code> private	{ keyword KwPrivate }
<0,code> Set		{ keyword KwSet }
<0,code> Prop		{ keyword KwProp }
<0,code> Set @number	{ withRange' (read . drop 3) TokSetN }

-- The parser is responsible to put the lexer in the imp_dir_ state when it
-- expects an import directive keyword. This means that if you run the
-- tokensParser you will never see these keywords.
<imp_dir_> using	{ endWith $ keyword KwUsing }
<imp_dir_> hiding	{ endWith $ keyword KwHiding }
<imp_dir_> renaming	{ endWith $ keyword KwRenaming }
<imp_dir_> to		{ endWith $ keyword KwTo }

-- Holes
<0,code> "{!"		{ hole }

-- Special symbols
<0,code> "."		{ symbol SymDot }
<0,code> ","		{ symbol SymComma }
<0,code> ";"		{ symbol SymSemi }
<0,code> "`"		{ symbol SymBackQuote }
<0,code> ":"		{ symbol SymColon }
<0,code> "="		{ symbol SymEqual }
<0,code> "_"		{ symbol SymUnderscore }
<0,code> "?"		{ symbol SymQuestionMark }
<0,code> "("		{ symbol SymOpenParen }
<0,code> ")"		{ symbol SymCloseParen }
<0,code> "["		{ symbol SymOpenBracket }
<0,code> "]"		{ symbol SymCloseBracket }
<0,code> "->"		{ symbol SymArrow }
<0,code> "\"		{ symbol SymLambda }
<0,code> "{"		{ openBrace }
<0,code> "}"		{ closeBrace }

-- Identifiers and operators
<0,code> @q_ident	{ identifier }
<0,code> @q_operator	{ operator }

-- Literals
<0,code> \'		{ litChar }
<0,code> \"		{ litString }
<0,code> @number	{ literal LitInt }
<0,code> @float		{ literal LitFloat }

{

-- | This is the initial state for parsing a literate file. Code blocks
--   should be enclosed in @\\begin{code}@ @\\end{code}@ pairs.
literate :: LexState
literate = tex


-- | This is the initial state for parsing a regular, non-literate file.
normal :: LexState
normal = 0


{-| The layout state. Entered when we see a layout keyword ('withLayout') and
    exited either when seeing an open brace ('openBrace') or at the next token
    ('newLayoutContext').
-}
layout :: LexState
layout = layout_


{-| We enter this state from 'newLayoutContext' when the token following a
    layout keyword is to the left of (or at the same column as) the current
    layout context. Example:

    > data Empty : Set where
    > foo : Empty -> Nat

    Here the second line is not part of the @where@ clause since it is has the
    same indentation as the @data@ definition. What we have to do is insert an
    empty layout block @{}@ after the @where@. The only thing that can happen
    in this state is that 'emptyLayout' is executed, generating the closing
    brace. The open brace is generated when entering by 'newLayoutContext'.
-}
empty_layout :: LexState
empty_layout = empty_layout_


-- | This state is entered at the beginning of each line. You can't lex
--   anything in this state, and to exit you have to check the layout rule.
--   Done with 'offsideRule'.
bol :: LexState
bol = bol_


-- | This state can only be entered by the parser. In this state you can only
--   lex the keywords @using@, @hiding@, @renaming@ and @to@. Moreover they are
--   only keywords in this particular state. The lexer will never enter this
--   state by itself, that has to be done in the parser.
imp_dir :: LexState
imp_dir = imp_dir_


-- | Return the next token. This is the function used by Happy in the parser.
--
--   @lexer k = 'lexToken' >>= k@
lexer :: (Token -> Parser a) -> Parser a
lexer k = lexToken >>= k

-- | This is main lexing function generated by Alex.
alexScan :: AlexInput -> Int -> AlexReturn (LexAction Token)

}
