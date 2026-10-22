-- 0234 — Fixed search_path on four portal helpers (security advisor, 21 Oct 2026).
alter function public.portal_request_name(text, text) set search_path = public;
alter function public.portal_request_category(text) set search_path = public;
alter function public.portal_terms_frozen() set search_path = public;
alter function public.portal_append_only() set search_path = public;
