-- ============================================================================
-- Migration 25: Attach missing bank-balance net-worth trigger
-- Goal:
--   make bank_accounts mutations reconcile users.net_worth through the
--   canonical helper, matching the documented trigger surface.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.trg_bank_balance_reconcile_net_worth()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := COALESCE(NEW.user_id, OLD.user_id);

    UPDATE users
    SET net_worth = calculate_user_net_worth(v_user_id)
    WHERE id = v_user_id;

    RETURN COALESCE(NEW, OLD);
END;
$function$;

DROP TRIGGER IF EXISTS trg_bank_balance_reconcile_net_worth ON public.bank_accounts;
CREATE TRIGGER trg_bank_balance_reconcile_net_worth
    AFTER INSERT OR DELETE OR UPDATE OF balance, user_id
    ON public.bank_accounts
    FOR EACH ROW
    EXECUTE FUNCTION trg_bank_balance_reconcile_net_worth();
