
module Lambda where

open import Prelude
open import Star
open import Examples
open import Modal

-- Environments

data Ty : Set where
  nat : Ty
  _⟶_ : Ty -> Ty -> Ty

Ctx : Set
Ctx = List Ty

Var : Ctx -> Ty -> Set
Var Γ τ = Any (_==_ τ) Γ

data Tm : Ctx -> Ty -> Set where
  var : forall {Γ τ} -> Var Γ τ -> Tm Γ τ
  zz  : forall {Γ} -> Tm Γ nat
  ss  : forall {Γ} -> Tm Γ (nat ⟶ nat)
  λ   : forall {Γ σ τ} -> Tm (σ • Γ) τ -> Tm Γ (σ ⟶ τ)
  _$_ : forall {Γ σ τ} -> Tm Γ (σ ⟶ τ) -> Tm Γ σ -> Tm Γ τ

ty⟦_⟧ : Ty -> Set
ty⟦ nat   ⟧ = Nat
ty⟦ σ ⟶ τ ⟧ = ty⟦ σ ⟧ -> ty⟦ τ ⟧

Env : Ctx -> Set
Env = All ty⟦_⟧

_[_] : forall {Γ τ} -> Env Γ -> Var Γ τ -> ty⟦ τ ⟧
ρ [ x ] with lookup x ρ
ρ [ x ] | result _ refl v = v

⟦_⟧_ : forall {Γ τ} -> Tm Γ τ -> Env Γ -> ty⟦ τ ⟧
⟦ var x ⟧ ρ = ρ [ x ]
⟦ zz    ⟧ ρ = zero
⟦ ss    ⟧ ρ = suc
⟦ λ t   ⟧ ρ = \x -> ⟦ t ⟧ (check x • ρ)
⟦ s $ t ⟧ ρ = (⟦ s ⟧ ρ) (⟦ t ⟧ ρ)

tm : Tm ε nat
tm = (λ (var (done refl • ε))) $ (ss $ zz)

one : Nat
one = ⟦ tm ⟧ ε