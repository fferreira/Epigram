\section{Elaboration}

%if False

> {-# OPTIONS_GHC -F -pgmF she #-}
> {-# LANGUAGE ScopedTypeVariables, TypeOperators, TypeSynonymInstances, GADTs #-}

> module DisplayLang.Elaborator where

> import Control.Applicative
> import Control.Monad
> import Data.Traversable

> import Kit.BwdFwd
> import Kit.MissingLibrary

> import ProofState.Developments
> import ProofState.ProofContext
> import ProofState.ProofState
> import ProofState.ProofKit

> import DisplayLang.DisplayTm
> import DisplayLang.Naming

> import Evidences.Rules
> import Evidences.Tm

> import NameSupply.NameSupplier

%endif


The |elaborate| command elaborates a term in display syntax, given its type,
to produce an elaborated term and its value representation. It behaves
similarly to |check| from subsection~\ref{subsec:type-checking}, except that
it operates in the |ProofState| monad, so it can create subgoals and
$\lambda$-lift terms.

> elabbedT :: INTM -> ProofState (INTM :=>: VAL)
> elabbedT t = return (t :=>: evTm t)


The Boolean parameter indicates whether the elaborator is working at the top
level of the term, because if so, it can create boys in the current development
rather than creating a subgoal.

> elaborate :: Bool -> (TY :>: InDTmRN) -> ProofState (INTM :=>: VAL)

> import <- ElaborateRules

First, some special cases to provide a convenient syntax for writing functions from
interesting types.

> elaborate b (PI UNIT t :>: DCON f) = do
>     (m' :=>: m) <- elaborate False (t $$ A VOID :>: f)
>     return $ L (K m') :=>: L (K m)

> elaborate False (y@(PI _ _) :>: t@(DC _)) = do
>     y' <- bquoteHere y
>     h <- pickName "h" ""
>     make (h :<: y')
>     goIn
>     neutralise =<< elabGive t

> elaborate True (PI (MU l d) t :>: DCON f) = do
>     (m' :=>: _) <- elaborate False $ case l of
>       Nothing  -> elimOpMethodType $$ A d $$ A t :>: f
>       Just l   -> elimOpLabMethodType $$ A l $$ A d $$ A t :>: f
>     d' <- bquoteHere d
>     t' <- bquoteHere t
>     x <- lambdaBoy (fortran t)
>     elabbedT . N $ elimOp :@ [d', N (P x), t', m']

> elaborate True (PI (SIGMA d r) t :>: DCON f) = do
>     let mt =  PI d . L . HF (fortran r) $ \ a ->
>               PI (r $$ A a) . L . HF (fortran t) $ \ b ->
>               t $$ A (PAIR a b)
>     mt' <- bquoteHere mt
>     (m' :=>: m) <- elaborate False (mt :>: f)
>     x <- lambdaBoy (fortran t)
>     elabbedT . N $ ((m' :? mt') :$ A (N (P x :$ Fst))) :$ A (N (P x :$ Snd))

> elaborate True (PI (ENUMT e) t :>: m) | isTuply m = do
>     targetsDesc <- withNSupply (equal (ARR (ENUMT e) SET :>: (t, L (K desc))))
>     (m' :=>: _) <- elaborate False (branchesOp @@ [e, t] :>: m)
>     e' <- bquoteHere e
>     x  <- lambdaBoy (fortran t)
>     if targetsDesc
>       then elabbedT . N $ switchDOp :@ [e', m', N (P x)]
>       else do
>         t' <- bquoteHere t
>         elabbedT . N $ switchOp :@ [e', N (P x), t', m']
>  where   isTuply :: InDTmRN -> Bool
>          isTuply DVOID = True
>          isTuply (DPAIR _ _) = True
>          isTuply _ = False

> elaborate b (MONAD d x :>: DCON t) = elaborate b (MONAD d x :>: DCOMPOSITE t)
> elaborate b (QUOTIENT a r p :>: DPAIR x DVOID) =
>   elaborate b (QUOTIENT a r p :>: DCLASS x)

> elaborate b (PRF p :>: DVOID) = prove b p

> elaborate b (NU d :>: DCOIT DVOID sty f s) = do
>   d' <- bquoteHere d
>   elaborate b (NU d :>: DCOIT (DT (InTmWrap d')) sty f s)

Elaborating a canonical term with canonical type is a job for |canTy|.

> elaborate top (C ty :>: DC tm) = do
>     v <- canTy (elaborate False) (ty :>: tm)
>     return $ (C $ fmap (\(x :=>: _) -> x) v) :=>: (C $ fmap (\(_ :=>: x) -> x) v)


If the elaborator encounters a question mark, it simply creates an appropriate subgoal.

> elaborate top (ty :>: DQ x) = do
>     ty' <- bquoteHere ty
>     neutralise =<< make (x :<: ty')


There are a few possibilities for elaborating $\lambda$-abstractions. If both the
range and term are constants, and we are not at top level, then we simply elaborate
underneath. This avoids creating some trivial children. It means that elaboration
will not produce a fully $\lambda$-lifted result, but luckily the compiler can deal
with constant functions.

> elaborate False (PI s (L (K t)) :>: DL (DK dtm)) = do
>     (tm :=>: tmv) <- elaborate False (t :>: dtm)
>     return (L (K tm) :=>: L (K tmv))

If we are not at top level, we create a subgoal corresponding to the term, solve it
by elaboration, then return the reference. 

> elaborate False (ty :>: DL sc) = do
>     Just _ <- return $ lambdable ty
>     pi' <- bquoteHere ty
>     h <- pickName "h" ""
>     make (h :<: pi')
>     goIn
>     l <- lambdaBoy (dfortran (DL sc))
>     neutralise =<< elabGive (underDScope sc l)

If we are at top level, we can simply create a |lambdaBoy| in the current development,
and carry on elaborating.

> elaborate True (ty :>: DL sc) = do
>     Just _ <- return $ lambdable ty
>     l <- lambdaBoy (dfortran (DL sc))
>     _ :=>: ty <- getGoal "elaborate lambda"
>     elaborate True (ty :>: underDScope sc l)
>     
    
Much as with type-checking, we push types in to neutral terms by calling
|elabInfer| on the term, then checking the inferred type is what we pushed in.

> elaborate top (w :>: DN n) = do
>   (nn :<: y) <- elabInfer n
>   eq <- withNSupply (equal (SET :>: (w, y)))
>   guard eq `replaceError` unlines ["elaborate: inferred type", show y,
>                                    "of", show n, "is not", show w]
>   neutralise nn


If the elaborator made up a term, it does not require further elaboration, but
we should type-check it for safety's sake. 

> elaborate top (ty :>: DT (InTmWrap tm)) = checkHere (ty :>: tm)

If nothing else matches, give up and report an error.

> elaborate top tt = throwError' ("elaborate: can't cope with " ++ show tt)


The |elabInfer| command is to |infer| in subsection~\ref{subsec:type-inference} 
as |elaborate| is to |check|. It infers the type of a display term, calling on
the elaborator rather than the type-checker. Most of the cases are similar to
those of |infer|.

> elabInfer :: ExDTmRN -> ProofState (EXTM :=>: VAL :<: TY)

> elabInfer (DP x) = do
>     (ref, as) <- elabResolve x
>     let tm = P ref $:$ as
>     ty <- withNSupply (typeCheck $ infer tm)
>     (tmv :<: ty') <- ty `catchEither` "elabInfer: inference failed!"
>     return $ (tm :=>: tmv) :<: ty'

> elabInfer (tm ::$ Call _) = do
>     ((tm' :=>: tmv) :<: LABEL l ty) <- elabInfer tm
>     l' <- bquoteHere l
>     return $ (tm' :$ Call l') :=>: (tmv $$ Call l) :<: ty

> elabInfer (t ::$ s) = do
>     ((t' :=>: tv) :<: C ty) <- elabInfer t
>     (s', ty') <- elimTy (elaborate False) (tv :<: ty) s
>     return $ (t' :$ fmap termOf s') :=>: (tv $$ fmap valueOf s') :<: ty'

> elabInfer (DType ty) = do
>     (ty' :=>: vty)  <- elaborate False (SET :>: ty)
>     x <- pickName "x" ""
>     return $ (idTM x :? ARR ty' ty') :=>: idVAL x :<: ARR vty vty

> elabInfer tt = throwError' ("elabInfer: can't cope with " ++ show tt)


\subsection{Proof Construction}

This operation, part of elaboration, tries to prove a proposition, leaving the
hard bits for the human.

> prove :: Bool -> VAL -> ProofState (INTM :=>: VAL)
> prove b TRIVIAL = return (VOID :=>: VOID)
> prove b (AND p q) = do
>   (pt :=>: pv) <- prove False p
>   (qt :=>: qv) <- prove False q
>   return (PAIR pt qt :=>: PAIR pv qv)
> prove b p@(ALL _ _) = elaborate b (PRF p :>: DL ("__prove" ::. DVOID))
> prove b p@(EQBLUE (y0 :>: t0) (y1 :>: t1)) = useRefl <|> unroll <|> search p where
>   useRefl = do
>     guard =<< withNSupply (equal (SET :>: (y0, y1)))
>     guard =<< withNSupply (equal (y0 :>: (t0, t1)))
>     let w = pval refl $$ A y0 $$ A t0
>     qw <- bquoteHere w
>     return (qw :=>: w)
>   unroll = do
>     Right p <- return $ opRun eqGreen [y0, t0, y1, t1]
>     (t :=>: v) <- prove False p
>     return (CON t :=>: CON v)
> prove b p@(N (qop :@ [y0, t0, y1, t1])) | qop == eqGreen = do
>   let g = EQBLUE (y0 :>: t0) (y1 :>: t1)
>   (_ :=>: v) <- prove False g
>   let v' = v $$ Out
>   t' <- bquoteHere v'
>   return (t' :=>: v')
> prove b p = search p

> search :: VAL -> ProofState (INTM :=>: VAL)
> search p = do
>   es <- getAuncles
>   aunclesProof es p <|> elaborate False (PRF p :>: DQ "")

> aunclesProof :: Entries -> VAL -> ProofState (INTM :=>: VAL)
> aunclesProof B0 p = empty
> aunclesProof (es :< E ref _ (Boy _) _) p =
>   synthProof (pval ref :<: pty ref) p <|> aunclesProof es p
> aunclesProof (es :< _) p = aunclesProof es p  -- for the time being

> synthProof :: (VAL :<: TY) -> VAL -> ProofState (INTM :=>: VAL)
> synthProof (v :<: PRF p) p' = do
>   guard =<< withNSupply (equal (PROP :>: (p, p')))
>   t <- bquoteHere v
>   return (t :=>: v)
> synthProof _ _ = (|)


The |elabResolve| command resolves a relative name to a reference
and a spine of shared parameters to which it should be applied.

> elabResolve :: RelName -> ProofState (REF, Spine {TT} REF)
> elabResolve x = do
>    aus <- getAuncles
>    findGlobal aus x `catchEither` "elabResolve: cannot resolve name"
>    


\subsection{Elaborated Construction Commands}


The |elabGive| command elaborates the given display term in the appropriate type for
the current goal, and calls the |give| command on the resulting term. If its argument
is a nameless question mark, it avoids creating a pointless subgoal by simply returning
a reference to the current goal (applied to the appropriate shared parameters).

> elabGive :: InDTmRN -> ProofState (EXTM :=>: VAL)
> elabGive tm = elabGive' tm <* goOut

> elabGiveNext :: InDTmRN -> ProofState (EXTM :=>: VAL)
> elabGiveNext tm = elabGive' tm <* (nextGoal <|> goOut)

> elabGive' :: InDTmRN -> ProofState (EXTM :=>: VAL)
> elabGive' tm = do
>     tip <- getDevTip
>     case tip of         
>         Unknown (tipTyTm :=>: tipTy) -> do
>             case tm of
>                 DQ "" -> do
>                     GirlMother ref _ _ <- getMother
>                     aus <- getGreatAuncles
>                     return (applyAuncles ref aus)
>                 _ -> do
>                     (tm' :=>: tv) <- elaborate True (tipTy :>: tm)
>                     give' tm'
>         _  -> throwError' "elabGive: only possible for incomplete goals."


The |elabMake| command elaborates the given display term in a module to
produce a type, then converts the module to a goal with that type. Thus any
subgoals produced by elaboration will be children of the resulting goal.

> elabMake :: (String :<: InDTmRN) -> ProofState (EXTM :=>: VAL)
> elabMake (s :<: ty) = do
>     makeModule s
>     goIn
>     ty' :=>: _ <- elaborate False (SET :>: ty)
>     tm <- moduleToGoal ty'
>     goOut
>     return tm

elabProgram adds a label to a type, given a list of arguments.
e.g. with a goal plus : nat -> nat -> nat, 
program x,y will give a proof state of:

[ plus : \ x y c -> c call : (x:N)->(y:N)-><plus x y : N>->N
  g : (x:N)->(y:N)-><plus x y : N>
  x : N
  y : N  (from lambdaboy)
] g x y call   (from giveNext, then we're ready to go).

> elabProgram :: [String] -> ProofState (EXTM :=>: VAL)
> elabProgram args = do
>     n <- getMotherName
>     (_ :=>: g) <- getHoleGoal
>     let pn = P (n := FAKE :<: g)
>     let newty = pity (mkTel pn g [] args)
>     newty' <- bquoteHere newty
>     g :=>: _ <- make ("g" :<: newty') 
>     argrefs <- traverse lambdaBoy args
>     let fcall = pn $## (map NP argrefs) 
>     let call = g $## (map NP argrefs) :$ Call (N fcall)
>     giveNext (N call)
>   where mkTel :: NEU -> TY -> [VAL] -> [String] -> TEL TY
>         mkTel n (PI s t) args (x:xs)
>            = (x :<: s) :-: (\val -> mkTel n (t $$ A val) (val:args) xs)
>         mkTel n r args _ = Target (LABEL (mkL n (reverse args)) r)
>         
>         mkL :: NEU -> [VAL] -> VAL
>         mkL n [] = N n
>         mkL n (x:xs) = mkL (n :$ (A x)) xs


The |elabPiBoy| command elaborates the given display term to produce a type, and
creates a $\Pi$-boy with that type.

> elabPiBoy :: (String :<: InDTmRN) -> ProofState REF
> elabPiBoy (s :<: ty) = do
>     tt <- elaborate True (SET :>: ty)
>     piBoy' (s :<: tt)

> elabLamBoy :: (String :<: InDTmRN) -> ProofState REF
> elabLamBoy (s :<: ty) = do
>     tt <- elaborate True (SET :>: ty)
>     lambdaBoy' (s :<: tt)

