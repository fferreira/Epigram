\section{Nu}

%if False

> {-# OPTIONS_GHC -F -pgmF she #-}

> module Features.Nu where

%endif

> import -> CanConstructors where
>   Nu :: t -> Can t
>   CoIt :: t -> t -> t -> t -> Can t

> import -> TraverseCan where
>   traverse f (Nu t) = (|Nu (f t)|)
>   traverse f (CoIt d sty g s) = (|CoIt (f d) (f sty) (f g) (f s)|)

> import -> HalfZipCan where
>   halfZip (Nu t0) (Nu t1)  = Just (Nu (t0,t1))
>   halfZip (CoIt d0 sty0 g0 s0) (CoIt d1 sty1 g1 s1) = 
>     Just (CoIt (d0,d1) (sty0,sty1) (g0,g1) (s0,s1))

> import -> CanPats where
>   pattern NU t = C (Nu t)
>   pattern COIT d sty f s = C (CoIt d sty f s)

> import -> DisplayCanPats where
>   pattern DNU t = DC (Nu t)
>   pattern DCOIT d sty f s = DC (CoIt d sty f s)

> import -> CanPretty where
>   pretty (Nu t)  = wrapDoc (kword KwNu <+> pretty t ArgSize) ArgSize
>   pretty (CoIt d sty f s) = wrapDoc
>       (kword KwCoIt <+> pretty sty ArgSize
>            <+> pretty f ArgSize <+> pretty s ArgSize)
>       ArgSize

> import -> CanTyRules where
>   canTy chev (Set :>: Nu x)     = do
>     xxv <- chev (desc :>: x)
>     return $ Nu xxv
>   canTy chev (t@(Nu x) :>: Con y) = do
>     yyv <- chev (descOp @@ [x, C t] :>: y)
>     return $ Con yyv
>   canTy chev (Nu x :>: CoIt d sty f s) = do
>     dv <- chev (desc :>: d)
>     sstyv@(sty :=>: styv) <- chev (SET :>: sty)
>     fv <- chev (ARR styv (descOp @@ [x,styv]) :>: f)
>     sv <- chev (styv :>: s)
>     return (CoIt dv sstyv fv sv)

> import -> CanCompile where
>   makeBody (Nu t) = Ignore
>   makeBody (CoIt d _ f s) = App (Var "__coit") (map makeBody [d,f,s])

> import -> ElimTyRules where
>   elimTy chev (_ :<: t@(Nu d)) Out = return (Out, descOp @@ [d , C t])

> import -> ElimComputation where
>   COIT d sty f s $$ Out = mapOp @@ [d, sty, NU d,
>     L . HF "s" $ \ s -> COIT d sty f s,
>     f $$ A s]
