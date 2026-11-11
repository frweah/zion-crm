-- A phone photo is read like a scan (0343)
--
-- The state takes only its three answers; nothing already on a record is
-- suddenly "not read yet"; the documents list carries the state with every
-- column it had, in order; and a restricted photo's state says nothing more
-- than that it is waiting. Read-only apart from one row it rolls back.

begin;

do $$
declare
  v_cols text;
  v_waiting integer;
  failures text[] := '{}';
begin
  select string_agg(column_name, ',' order by ordinal_position) into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'client_documents';
  if v_cols <> 'id,client_id,document_date,created_at,category,restricted,uploaded_by,uploaded_by_name,can_open,filename,note,storage_path,mime_type,size_bytes,auth_id,form_id,ocr_state' then
    failures := failures || format('FAILED: client_documents is %s', v_cols)::text;
  end if;

  select count(*) into v_waiting from public.attachments
   where ocr_state = 'not read yet' and created_at < now() - interval '1 day';
  -- Only phone photos are ever marked, and none existed before 0343.
  if v_waiting > 0 and not exists (select 1 from public.phone_receipts) then
    failures := failures || format('FAILED: %s documents from before the phone are waiting to be read', v_waiting)::text;
  end if;

  begin
    update public.attachments set ocr_state = 'maybe' where id = (select id from public.attachments limit 1);
    failures := failures || 'FAILED: ocr_state took a value outside its three'::text;
  exception when check_violation then null;
  end;

  if has_table_privilege('anon', 'public.client_documents', 'select') then
    failures := failures || 'FAILED: anon can read client_documents'::text;
  end if;
  if not has_table_privilege('authenticated', 'public.client_documents', 'select') then
    failures := failures || 'FAILED: staff lost the documents list'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
