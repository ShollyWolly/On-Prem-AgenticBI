-- The healthcheck sentinel -- deliberately the alphabetically LAST file. During
-- initdb the temp server listens on a unix socket only, so a socket-based
-- pg_isready reports "ready" mid-seed and Cube would start against half-loaded
-- Pagila. The compose healthcheck needs BOTH gates: pg_isready -h 127.0.0.1
-- (forces TCP, the real server) and `select 1 from seed_complete` (proves the
-- date shift finished). Neither alone is sufficient.

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
