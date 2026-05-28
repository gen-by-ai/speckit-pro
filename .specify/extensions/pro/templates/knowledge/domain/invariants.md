# Invariants

Rules that must **never** break without an explicit ADR and human review.
The implement loop, evaluator, and reconcile command treat violations here as high severity.

## Global

- _(e.g. All writes to shared entities go through the repository layer — no ad-hoc SQL in handlers.)_

## Per bounded context

### _(context name)_

- _(invariant)_
