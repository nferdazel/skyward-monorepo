-- FIX: Add search_path to all SECURITY DEFINER functions
-- Prevents schema poisoning attacks
-- Applied to production on 2026-06-25

ALTER FUNCTION public.bot_finance_aircraft(p_bot_id uuid, p_aircraft_model_id uuid, p_down_payment_pct numeric, p_term_months integer) SET search_path TO 'public';
ALTER FUNCTION public.bot_take_loan(p_bot_id uuid, p_principal numeric, p_term_weeks integer) SET search_path TO 'public';
ALTER FUNCTION public.calculate_user_net_worth(p_user_id uuid) SET search_path TO 'public';
ALTER FUNCTION public.check_achievements(p_user_id uuid, p_game_time timestamp with time zone) SET search_path TO 'public';
ALTER FUNCTION public.compact_bank_transactions(p_dry_run boolean) SET search_path TO 'public';
ALTER FUNCTION public.compact_world_tick_log(p_dry_run boolean) SET search_path TO 'public';
ALTER FUNCTION public.configure_aircraft_seats(p_user_id uuid, p_fleet_id uuid, p_economy_seats integer, p_business_seats integer, p_first_class_seats integer) SET search_path TO 'public';
ALTER FUNCTION public.create_route(p_user_id uuid, p_origin_iata character varying, p_destination_iata character varying, p_distance_km numeric, p_ticket_price numeric, p_flights_per_week integer) SET search_path TO 'public';
ALTER FUNCTION public.credit_bank_account(p_user_id uuid, p_amount numeric, p_ifrs_category character varying, p_ifrs_subcategory character varying, p_description text, p_game_date timestamp with time zone) SET search_path TO 'public';
ALTER FUNCTION public.debit_bank_account(p_user_id uuid, p_amount numeric, p_ifrs_category character varying, p_ifrs_subcategory character varying, p_description text, p_game_date timestamp with time zone) SET search_path TO 'public';
ALTER FUNCTION public.delete_route(p_user_id uuid, p_route_id uuid) SET search_path TO 'public';
ALTER FUNCTION public.finance_aircraft(p_user_id uuid, p_aircraft_model_id uuid, p_down_payment_pct numeric, p_term_months integer) SET search_path TO 'public';
ALTER FUNCTION public.get_bot_health() SET search_path TO 'public';
ALTER FUNCTION public.get_competitor_insights(p_id uuid, p_is_bot boolean) SET search_path TO 'public';
ALTER FUNCTION public.get_current_user_id() SET search_path TO 'public';
ALTER FUNCTION public.get_database_size_report() SET search_path TO 'public';
ALTER FUNCTION public.get_finance_snapshot(p_id uuid, p_is_bot boolean) SET search_path TO 'public';
ALTER FUNCTION public.get_global_leaderboard() SET search_path TO 'public';
ALTER FUNCTION public.get_user_id_for_auth_uid(p_auth_user_id uuid) SET search_path TO 'public';
ALTER FUNCTION public.get_world_tick_log_compaction_report() SET search_path TO 'public';
ALTER FUNCTION public.handle_new_auth_user() SET search_path TO 'public';
ALTER FUNCTION public.process_aircraft_financing_payments(p_user_id uuid, p_game_date timestamp with time zone) SET search_path TO 'public';
ALTER FUNCTION public.refinance_loan(p_loan_id uuid) SET search_path TO 'public';
ALTER FUNCTION public.repair_aircraft(p_user_id uuid, p_fleet_id uuid) SET search_path TO 'public';
ALTER FUNCTION public.reset_user_airline(p_user_id uuid) SET search_path TO 'public';
ALTER FUNCTION public.save_airline_settings(p_user_id uuid, p_company_name character varying, p_auto_grounding_threshold numeric, p_hq_airport_iata character varying) SET search_path TO 'public';
ALTER FUNCTION public.sell_aircraft(p_user_id uuid, p_fleet_id uuid) SET search_path TO 'public';
ALTER FUNCTION public.take_loan(p_user_id uuid, p_principal numeric, p_term_weeks integer, p_loan_type character varying, p_collateral_aircraft_id uuid) SET search_path TO 'public';
ALTER FUNCTION public.terminate_aircraft_lease(p_user_id uuid, p_fleet_id uuid) SET search_path TO 'public';
ALTER FUNCTION public.update_route_frequency_and_price(p_user_id uuid, p_route_id uuid, p_ticket_price numeric, p_flights_per_week integer) SET search_path TO 'public';
