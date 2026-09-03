
-- This marker lets service health checks confirm that warehouse initialization completed.
CREATE TABLE public.seed_complete (
  id           integer PRIMARY KEY DEFAULT 1,
  completed_at timestamptz NOT NULL DEFAULT now(),
  rentals      bigint,
  payments     bigint,
  revenue      numeric(12,2),
  max_rental   timestamptz,
  max_payment  timestamptz,
  CONSTRAINT seed_complete_singleton CHECK (id = 1)
);

INSERT INTO public.seed_complete (rentals, payments, revenue, max_rental, max_payment)
SELECT (SELECT count(*)         FROM public.rental),
       (SELECT count(*)         FROM public.payment),
       (SELECT sum(amount)      FROM public.payment),
       (SELECT max(rental_date) FROM public.rental),
       (SELECT max(payment_date) FROM public.payment);

GRANT SELECT ON public.seed_complete TO cube_ro;

\echo ''
\echo '============================================================'
\echo ' SEED COMPLETE'
\echo '============================================================'
SELECT rentals, payments, revenue, max_rental, max_payment FROM public.seed_complete;
