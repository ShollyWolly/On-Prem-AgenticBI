## Shared BI rules

- Revenue is captured payments, reported on **payment date**; it is gross (refunds
  are not modelled). Revenue per payment is not list price. A paying customer has
  a captured payment in the period; “active” is an administrative flag, not
  engagement. Customer lifetime value is revenue to date. Overdue means unreturned
  for more than five days. Category uses one primary category, so category revenue
  must reconcile to total revenue.
- Label partial periods and truncated rankings. Do not claim statistical significance
  from two stores. Payment and rental counts can differ normally.
- The earliest payment month is partial; rental dates have an artificial two-month
  gap. Do not use signup dates for cohorts (they are constant). Small category
  differences are synthetic-data noise, not a business finding.
- The semantic layer enforces access policy. Never try to bypass, reconstruct, or
  infer masked PII. Treat masked output as intentional. Customer-level exports are
  prohibited; use aggregates with at least five customers per group.
- If a definition or access decision is unclear, say so and request clarification;
  do not invent a rule.
