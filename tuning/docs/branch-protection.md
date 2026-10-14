# Main branch protection

The `main` branch of this repository is protected by a ruleset with **no
standing bypass actors**: no user or role can bypass the required checks
(lint + build-test) in normal operation. `main` must never be updated without
the required CI passing.

## Emergency procedure: temporary owner bypass during a CI outage

If GitHub Actions is unavailable (for example, during a prolonged outage) and an
urgent fix must land on `main`, the following recovery path applies:

1. The repository owner (**danieljustus**) temporarily adds themselves as a
   bypass actor on the main protection ruleset with `bypass_mode: always`.
2. The owner records a **dated comment** on the ruleset explaining why the
   bypass was added and when.
3. The urgent change is reviewed and merged as usual.
4. **Immediately after recovery** (CI is back online and the fix is verified),
   the owner removes the temporary bypass actor and restores the
   no-standing-bypass state.

The temporary bypass must never remain in place after the outage is resolved.
