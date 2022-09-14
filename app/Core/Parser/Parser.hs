{-# LANGUAGE BlockArguments #-}
module Core.Parser.Parser where
  import Text.Parsec
  import Text.Parsec.Expr
  import Text.Parsec.Char
  import Text.Parsec.String
  import Data.Functor
  import qualified Text.Parsec.Token as Token
  import Text.Parsec.Language (emptyDef)
  import Text.Parsec.Token (GenTokenParser)
  import Data.Functor.Identity (Identity)
  import Control.Applicative (Alternative(some))
  import Core.Parser.AST
  import Debug.Trace (traceShow)
  import Data.Maybe (fromMaybe)
  
  {- LEXER PART -}
  languageDef =
    emptyDef {  Token.commentStart    = "/*"
              , Token.commentEnd      = "*/"
              , Token.commentLine     = "//"
              , Token.identStart      = letter
              , Token.identLetter     = alphaNum
              , Token.reservedNames   = ["let", "=", "fun", "if", "then", "else", "return", "extern", "match", "in"]
              , Token.reservedOpNames = ["(", ")", "*", "+", "-", "/", "{", "}", "[", "]", "->"] }

  lexer :: GenTokenParser String u Identity
  lexer = Token.makeTokenParser languageDef

  identifier :: Parser String
  identifier = Token.identifier lexer

  reserved :: String -> Parser ()
  reserved = Token.reserved lexer

  reservedOp :: String -> Parser ()
  reservedOp = Token.reservedOp lexer

  parens :: Parser a -> Parser a
  parens = Token.parens lexer

  integer :: Parser Integer
  integer = Token.integer lexer

  whiteSpace :: Parser ()
  whiteSpace = Token.whiteSpace lexer

  comma :: Parser String
  comma = Token.comma lexer

  commaSep :: Parser a -> Parser [a]
  commaSep = Token.commaSep lexer

  semi :: Parser String
  semi = Token.semi lexer

  {- PARSER PART -}

  type Pure a = Parser (Located a)

  parser :: Pure Statement
  parser = whiteSpace *> statement

  locate :: Parser a -> Pure a
  locate p = do
    start <- getPosition
    r <- p
    end <- getPosition
    return (r :> (start, end))

  -- Type parsing --

  generics :: Parser [String]
  generics = reservedOp "<" *> commaSep identifier <* reservedOp ">"

  type' :: Parser Declaration 
  type' =  try (string "char" $> CharE) 
       <|> application <|> struct <|> ref <|> custom
       <|> try (string "str" $> StrE) 
       <|> try (string "int" $> IntE) 
       <|> try (string "float" $> FloatE)
       <|> arrow <|> generic <|> array
       <|> parens type'

  application :: Parser Declaration
  application = do
    f <- try $ identifier <* reservedOp "<"
    args <- commaSep type'
    reservedOp ">"
    return $ AppE f args

  struct :: Parser Declaration
  struct = do
    reserved "struct" 
    reservedOp "{"
    fields <- commaSep (do
      name <- identifier
      reserved ":"
      t <- type'
      return (name, t))
    whiteSpace *> reservedOp "}"
    return $ StructE fields

  field :: Parser (String, Declaration)
  field = do
    name <- identifier
    reservedOp ":"
    type' <- type'
    return (name, type')

  custom :: Parser Declaration
  custom = do
    reserved "extern"
    name <- identifier
    return (AppE name [])

  generic :: Parser Declaration 
  generic = Id <$> identifier

  array :: Parser Declaration 
  array = Array <$> Token.brackets lexer type'
  
  arrow :: Parser Declaration 
  arrow = do
    reserved "fun"
    annot <- fromMaybe [] <$> optionMaybe generics
    args <- parens $ commaSep type'
    Arrow annot args <$> type'

  ref :: Parser Declaration
  ref = do
    reserved "ref"
    Ref <$> type'

  -- Statement parsing --

  statement :: Pure Statement
  statement = choice [
      enum,
      modification,
      try stmtExpr,
      functionStmt,
      assignment,
      condition,
      return',
      block
    ]

  enum :: Pure Statement
  enum = do
    s <- getPosition
    reserved "enum"
    name <- identifier
    gen <- fromMaybe [] <$> optionMaybe generics
    reservedOp "{"
    values <- commaSep enumField
    reservedOp "}"
    e <- getPosition
    return $ Enum name gen values :> (s, e)

  enumField :: Parser (String, Maybe [Declaration])
  enumField = do
    name <- identifier
    ty <- optionMaybe $ parens (commaSep type') 
    return (name, ty)

  return' :: Pure Statement
  return' = do
    s <- getPosition
    reserved "return"
    r <- expression
    e <- getPosition
    return (Return r :> (s, e))

  condition :: Pure Statement
  condition = do
    s <- getPosition
    reserved "if"
    cond <- expression <?> "condition"
    stmt <- statement <?> "then statement"
    reserved "else"
    stmt2 <- statement <?> "else statement"
    s2 <- getPosition
    return $ If cond stmt stmt2 :> (s, s2)

  stmtExpr :: Pure Statement
  stmtExpr = do
    e :> s <- expression
    return (Expression e :> s)

  modification :: Pure Statement
  modification = do
    s <- getPosition
    name <- try $ expression <* reservedOp "="
    e <- expression
    s2 <- getPosition
    return (Modified name e :> (s, s2))

  assignment :: Pure Statement
  assignment = do
    s <- getPosition
    reserved "let"
    (lhs :> _) <- annoted
    whiteSpace >> reserved "="
    rhs <- expression
    e <- getPosition
    return (Assignment lhs rhs :> (s, e))

  block :: Pure Statement
  block = do
    (_ :> s) <- locate $ reserved "{"
    stmts <- many statement <?> "statement"
    reserved "}"
    return (Sequence stmts :> s)

  functionStmt :: Pure Statement
  functionStmt = do
    s <- getPosition
    reserved "fun"
    name <- identifier
    gen <- fromMaybe [] <$> optionMaybe generics
    args <- parens $ commaSep annoted
    let args' = map (\(a :> _) -> a) args
    ret <- type'
    body <- spaces *> block
    e <- getPosition
    return $ Assignment (name :@ Nothing) (Lambda gen args' body :> (s, e)) :> (s, e)

  -- Expression parsing --

  expression :: Pure Expression
  expression = buildExpressionParser table term
  
  term :: Pure Expression
  term = try float <|> number <|> stringLit <|> charLit <|> list
      <|> (letIn <?> "let expression")
      <|> (match <?> "pattern matching")
      <|> (structure <?> "structure")
      <|> (function <?> "lambda")
      <|> (variable <?> "variable")
      <|> (parens expression <?> "expression")

  letIn :: Pure Expression
  letIn = do
    s <- getPosition
    reserved "let"
    (lhs :> _) <- annoted 
    reserved "="
    rhs <- expression
    reserved "in"
    body <- expression
    e <- getPosition
    return $ LetIn lhs rhs body :> (s, e)

  match :: Pure Expression
  match = do
    s <- getPosition
    reserved "match"
    expr <- expression
    cases <- Token.braces lexer $ commaSep case'
    e <- getPosition
    return $ Match expr cases :> (s, e)
  
  case' :: Parser (Located Expression, Located Statement)
  case' = do
    expr <- expression
    reserved "->"
    stmt <- statement
    return (expr, stmt)


  structure :: Pure Expression
  structure = do
    s <- getPosition
    reserved "struct" >> reservedOp "{"
    fields <- commaSep (do
      f <- identifier
      reservedOp ":"
      t <- expression
      return (f, t))
    reservedOp "}"
    e <- getPosition
    return (Structure fields :> (s, e))
  
  float :: Pure Expression
  float = do
    s <- getPosition
    num <- many1 digit
    char '.'
    dec <- many1 digit
    e <- getPosition
    return $ Literal (F ((read (num ++ "." ++ dec) :: Float) :> (s, e))) :> (s, e)

  list :: Pure Expression
  list = do
    (elems :> pos) <- locate $ Token.brackets lexer (commaSep expression)
    return (List elems :> pos)

  charLit :: Pure Expression
  charLit = do
    s <- getPosition
    (c :> pos) <- locate $ Token.charLiteral lexer
    e <- getPosition
    return (Literal (C (c :> pos)) :> (s, e))

  stringLit :: Pure Expression
  stringLit = do
    s@(_ :> pos) <- locate $ Token.stringLiteral lexer
    return (Literal (S s) :> pos)

  number :: Pure Expression
  number = do
    (n :> s) <- locate integer
    return (Literal (I $ n :> s) :> s)

  variable :: Pure Expression
  variable = do
    (v :> s) <- locate identifier
    return (Variable v :> s)

  annoted :: Pure (Annoted String)
  annoted = do
    s <- getPosition
    v <- identifier
    ty <- optionMaybe $ reserved ":" *> type'
    s2 <- getPosition
    return ((v :@ ty) :> (s, s2))

  annoted' :: Parser a -> Pure (Annoted a)
  annoted' p = do
    s <- getPosition
    v <- p
    ty <- optionMaybe $ reserved ":" *> type'
    s2 <- getPosition
    return ((v :@ ty) :> (s, s2))

  function :: Pure Expression
  function = do
    s <- getPosition
    reserved "fun"
    annot <- fromMaybe [] <$> optionMaybe generics
    args <- parens $ commaSep annoted
    let args' = map (\(a :> _) -> a) args
    body <- statement <?> "function body"
    s2 <- getPosition
    return (Lambda annot args' body :> (s, s2))

  makeUnaryOp :: Alternative f => f (a -> a) -> f (a -> a)
  makeUnaryOp s = foldr1 (.) . reverse <$> some s

  loc :: Located a -> (SourcePos, SourcePos)
  loc (a :> s) = s

  table :: [[Operator String () Identity (Located Expression)]]
  table = [
      [Infix (do
        char '`'
        fun <- identifier
        char '`'
        return (\x@(_ :> (p, _)) y@(_ :> (_, e)) -> BinaryOp fun x y :> (p, e) )) AssocLeft],
      [Postfix $ makeUnaryOp postfix],
      [Prefix $ makeUnaryOp prefix],
      equalities,
      [Postfix $ do
        reserved "?"
        thn <- expression
        reserved ":"
        els <- expression
        return (\x@(_ :> (p, _)) -> Ternary x thn els :> (p, snd $ loc els))],
      [Infix (reservedOp "*" >> return (\x@(_ :> (s, _)) y@(_ :> (_, e)) -> BinaryOp "*" x y :> (s, e))) AssocLeft,
       Infix (reservedOp "/" >> return (\x@(_ :> (s, _)) y@(_ :> (_, e)) -> BinaryOp "/" x y :> (s, e))) AssocLeft],
      [Infix (reservedOp "+" >> return (\x@(_ :> (s, _)) y@(_ :> (_, e)) -> BinaryOp "+" x y :> (s, e))) AssocLeft,
       Infix (reservedOp "-" >> return (\x@(_ :> (s, _)) y@(_ :> (_, e)) -> BinaryOp "-" x y :> (s, e))) AssocLeft]
    ]
    where postfix = call <|> object <|> index
          call = do
            args <- parens $ commaSep expression
            e <- getPosition
            return $ \x@(_ :> (s, _)) -> FunctionCall x args :> (s, e)
          object = do
            reservedOp "."
            object <- identifier
            e <- getPosition
            return $ \x@(_ :> (_, s)) -> Object x object :> (e, s)
          index = do
            index' <- Token.brackets lexer expression
            e <- getPosition
            return $ \x@(_ :> (p, _)) -> Index x index' :> (p, e)

          -- Equality operators
          equalityOp = ["==", "!=", "<", ">", "<=", ">="]
          equalities = map (\op -> Infix (reservedOp op >> return (\x@(_ :> (s, _)) y@(_ :> (_, e)) -> BinaryOp op x y :> (s, e))) AssocLeft) equalityOp

          -- Prefix operators
          prefix = ref <|> unref
          ref = do
            s <- getPosition
            reserved "ref"
            return $ \x@(_ :> (_, e)) -> Reference x :> (s, e)
          unref = do
            s <- getPosition
            reservedOp "*"
            return $ \x@(_ :> (_, e)) -> Unreference x :> (s, e)
  parsePure :: String -> String -> Either ParseError [Located Statement]
  parsePure = runParser (many parser <* eof) ()