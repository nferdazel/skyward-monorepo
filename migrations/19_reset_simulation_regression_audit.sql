-- ============================================================================
-- SKYWARD RESET / SIMULATION REGRESSION AUDIT
-- ============================================================================
-- Verifies that a reset clears buffered simulation values and that the next
-- simulation tick cannot emit phantom ledger rows or move cash unexpectedly.
-- Execute manually in Supabase SQL Editor after applying migrations.
-- ============================================================================

DO $$
DECLARE
    v_user_id UUID;
    v_username VARCHAR := 'reset_audit_' || floor(extract(epoch FROM now()))::bigint::text;
    v_company_name VARCHAR := 'Reset Audit ' || floor(extract(epoch FROM now()))::bigint::text;
    v_buffered_revenue NUMERIC(20,2);
    v_buffered_ops_cost NUMERIC(20,2);
    v_buffered_lease_cost NUMERIC(20,2);
    v_cash_before NUMERIC(20,2);
    v_cash_after NUMERIC(20,2);
    v_ledger_count INT;
BEGIN
    SELECT user_id
    INTO v_user_id
    FROM register_company(
        v_username,
        'auditpass123',
        v_company_name,
        'Reset Auditor',
        'CGK'
    )
    WHERE success = TRUE;

    ASSERT v_user_id IS NOT NULL, 'register_company did not create an audit user.';

    UPDATE users
    SET buffered_revenue = 987654.32,
        buffered_ops_cost = 45678.90,
        buffered_lease_cost = 12345.67,
        last_active_at = NOW() - INTERVAL '1 day'
    WHERE id = v_user_id;

    PERFORM reset_user_airline(v_user_id);

    SELECT
        buffered_revenue,
        buffered_ops_cost,
        buffered_lease_cost,
        cash
    INTO
        v_buffered_revenue,
        v_buffered_ops_cost,
        v_buffered_lease_cost,
        v_cash_before
    FROM users
    WHERE id = v_user_id;

    ASSERT v_buffered_revenue = 0.00, 'buffered_revenue was not cleared by reset.';
    ASSERT v_buffered_ops_cost = 0.00, 'buffered_ops_cost was not cleared by reset.';
    ASSERT v_buffered_lease_cost = 0.00, 'buffered_lease_cost was not cleared by reset.';

    UPDATE users
    SET last_active_at = NOW() - INTERVAL '1 hour'
    WHERE id = v_user_id;

    PERFORM process_simulation_delta(v_user_id);

    SELECT cash INTO v_cash_after FROM users WHERE id = v_user_id;
    SELECT COUNT(*) INTO v_ledger_count FROM financial_ledger WHERE user_id = v_user_id;

    ASSERT v_ledger_count = 0, 'Reset user generated phantom ledger rows on next simulation tick.';
    ASSERT v_cash_after = v_cash_before, 'Reset user cash changed on next simulation tick without assets or routes.';

    DELETE FROM financial_ledger WHERE user_id = v_user_id;
    DELETE FROM user_routes WHERE user_id = v_user_id;
    DELETE FROM user_fleet WHERE user_id = v_user_id;
    DELETE FROM sessions WHERE user_id = v_user_id;
    DELETE FROM users WHERE id = v_user_id;
END $$;
