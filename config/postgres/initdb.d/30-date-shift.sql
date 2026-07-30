-- Relocates Pagila's all-2022 data into the trailing months, so "last 30 days"
-- filters do not return zero rows. Two INDEPENDENT shifts, not one: rental_date
-- and payment_date are generated independently in this fork (51% of rentals
-- postdate the last payment), so a single shared shift leaves payments ~37 days
-- in the past. Span is ~7.3 months and a shift cannot widen it -- "stretch to 24
-- months" was rejected because it multiplies rental duration by ~3.2x and makes
-- avg_rental_duration a lie. See docs/TRAPS.md.

\echo '>>> 30-date-shift: relocating Pagila into the trailing months'
\timing on

SET TIME ZONE 'UTC';

-- Suppresses the `last_updated` trigger on 15 tables and skips FK revalidation.
-- Without this, every UPDATE below stamps last_update = now() and destroys that
-- column. Requires superuser; initdb.d runs as POSTGRES_USER, so it holds.
SET session_replication_role = 'replica';

DO $shift$
DECLARE
  v_anchor  timestamptz := date_trunc('hour', now());
  v_rental  interval;
  v_payment interval;
  v_days    integer;
  v_min     timestamptz;
  v_max     timestamptz;
  v_m       timestamptz;
  v_part    text;
  v_rows    bigint;
BEGIN
  -- 1. Rental family. Same interval on all three columns, so rental DURATION is
  --    preserved exactly -- the only reason avg_rental_duration_days is
  --    trustworthy. Anchored on the later maximum so no return_date lands in
  --    the future.
  SELECT (v_anchor::date - GREATEST(max(rental_date), max(return_date))::date)
    INTO v_days
    FROM public.rental;
  v_rental := make_interval(days => v_days);
  RAISE NOTICE 'rental shift  : % (% days)', v_rental, v_days;

  UPDATE public.rental
     SET rental_date = rental_date + v_rental,
         return_date = return_date + v_rental,   -- NULL + interval = NULL
         last_update = last_update + v_rental;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RAISE NOTICE 'rental rows shifted: %', v_rows;

  -- 2. Dimension tables: same interval, to keep last_update coherent.
  --    customer.create_date is constant for all 599 rows upstream -- shifting
  --    keeps it constant, so no signup/cohort chart is possible from this data.
  UPDATE public.customer      SET create_date = create_date + v_rental,
                                  last_update = last_update + v_rental;
  UPDATE public.film          SET last_update = last_update + v_rental;
  UPDATE public.actor         SET last_update = last_update + v_rental;
  UPDATE public.address       SET last_update = last_update + v_rental;
  UPDATE public.category      SET last_update = last_update + v_rental;
  UPDATE public.city          SET last_update = last_update + v_rental;
  UPDATE public.country       SET last_update = last_update + v_rental;
  UPDATE public.film_actor    SET last_update = last_update + v_rental;
  UPDATE public.film_category SET last_update = last_update + v_rental;
  UPDATE public.inventory     SET last_update = last_update + v_rental;
  UPDATE public.language      SET last_update = last_update + v_rental;
  UPDATE public.staff         SET last_update = last_update + v_rental;
  UPDATE public.store         SET last_update = last_update + v_rental;

  -- 3. payment -- the hard one. It is PARTITION BY RANGE (payment_date), and
  --    Postgres can move rows across partitions on UPDATE only into a partition
  --    that already exists -- shifting by ~3.5 years puts every row outside all
  --    seven, so a plain UPDATE dies with "no partition of relation found".
  --    Strategy: stage -> drop old partitions -> create new monthly ones ->
  --    re-insert. Safe because nothing else references payment.
  SELECT (v_anchor::date - max(payment_date)::date)
    INTO v_days
    FROM public.payment;
  v_payment := make_interval(days => v_days);
  RAISE NOTICE 'payment shift : % (% days)', v_payment, v_days;

  -- 3a. Stage shifted rows OUTSIDE the partition tree.
  CREATE UNLOGGED TABLE public._payment_stage AS
  SELECT payment_id, customer_id, staff_id, rental_id, amount,
         payment_date + v_payment AS payment_date
    FROM public.payment;

  SELECT count(*), min(payment_date), max(payment_date)
    INTO v_rows, v_min, v_max
    FROM public._payment_stage;
  RAISE NOTICE 'staged % payments spanning % .. %', v_rows, v_min, v_max;

  -- 3b. Drop every existing partition (data is staged). Dropping also drops
  --     their per-partition FKs; re-added on the PARENT in 3e instead, which
  --     PG12+ then propagates to all future partitions automatically.
  FOR v_part IN
    SELECT c.relname
      FROM pg_class c
      JOIN pg_inherits i ON i.inhrelid = c.oid
     WHERE i.inhparent = 'public.payment'::regclass
     ORDER BY c.relname
  LOOP
    EXECUTE format('DROP TABLE public.%I', v_part);
    RAISE NOTICE '  dropped partition %', v_part;
  END LOOP;

  -- 3c. Create monthly partitions covering the shifted range, plus one month
  --     of headroom so the demo keeps accepting inserts for a while.
  v_m := date_trunc('month', v_min);
  WHILE v_m <= date_trunc('month', v_max) + interval '1 month' LOOP
    v_part := 'payment_p' || to_char(v_m, 'YYYY_MM');
    EXECUTE format(
      'CREATE TABLE public.%I PARTITION OF public.payment FOR VALUES FROM (%L) TO (%L)',
      v_part, v_m, v_m + interval '1 month');
    RAISE NOTICE '  created partition % [% .. %)', v_part, v_m, v_m + interval '1 month';
    v_m := v_m + interval '1 month';
  END LOOP;

  -- 3d. Re-insert; the partition router places each row.
  INSERT INTO public.payment (payment_id, customer_id, staff_id, rental_id, amount, payment_date)
  SELECT payment_id, customer_id, staff_id, rental_id, amount, payment_date
    FROM public._payment_stage;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RAISE NOTICE 'payment rows re-inserted: %', v_rows;

  DROP TABLE public._payment_stage;

  -- 3e. Re-establish the FKs once, on the parent.
  ALTER TABLE public.payment
    ADD CONSTRAINT payment_customer_id_fkey
      FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id),
    ADD CONSTRAINT payment_staff_id_fkey
      FOREIGN KEY (staff_id)    REFERENCES public.staff(staff_id),
    ADD CONSTRAINT payment_rental_id_fkey
      FOREIGN KEY (rental_id)   REFERENCES public.rental(rental_id);

  -- 3f. Re-inserting explicit ids does not advance the sequences.
  PERFORM setval('public.payment_payment_id_seq',
                 (SELECT max(payment_id) FROM public.payment));
  PERFORM setval('public.rental_rental_id_seq',
                 (SELECT max(rental_id) FROM public.rental));
END
$shift$;

-- rental_by_category was materialised over the pre-shift data.
REFRESH MATERIALIZED VIEW public.rental_by_category;

SET session_replication_role = 'origin';
ANALYZE;

-- Abort the container rather than ship an empty dashboard.
DO $verify$
DECLARE
  v_rentals  bigint;
  v_payments bigint;
  v_bad      bigint;
BEGIN
  SELECT count(*) INTO v_rentals
    FROM public.rental  WHERE rental_date  >= now() - interval '30 days';
  SELECT count(*) INTO v_payments
    FROM public.payment WHERE payment_date >= now() - interval '30 days';
  RAISE NOTICE 'last 30 days -> % rentals, % payments', v_rentals, v_payments;

  IF v_rentals = 0 THEN
    RAISE EXCEPTION 'date-shift failed: no rentals in the last 30 days';
  END IF;
  IF v_payments = 0 THEN
    RAISE EXCEPTION 'date-shift failed: no payments in the last 30 days';
  END IF;

  SELECT count(*) INTO v_bad
    FROM public.rental WHERE return_date < rental_date;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'date-shift corrupted % rental durations', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
    FROM public.payment WHERE payment_date > now() + interval '1 day';
  IF v_bad > 0 THEN
    RAISE EXCEPTION '% payments landed in the future', v_bad;
  END IF;

  -- Row counts must be exactly preserved by the partition rebuild.
  SELECT count(*) INTO v_payments FROM public.payment;
  IF v_payments <> 16049 THEN
    RAISE WARNING 'payment row count is % (expected 16049) -- upstream data may have changed', v_payments;
  END IF;
END
$verify$;

\echo '>>> 30-date-shift: done'
