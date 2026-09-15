-- Zion Vocational Rehab CRM — the rest of the screens consolidated (deploy 2)
--
-- Paid & outstanding counts invoices. The owner decided (14 Sept 2026) that
-- "received" means invoices marked Paid, and "outstanding" means authorizations
-- submitted for payment and not yet received - invoices Sent and not Paid. The
-- view counted the payments table, and outstanding as invoiced minus paid with
-- Drafts included. Now it agrees with A/R aging, Revenue and the KPIs. The
-- payments table stays the record behind each paid invoice: warrant, voucher,
-- page image.
--
-- Same columns, same order, same meaning of each name; only paid, outstanding,
-- last_paid_on and payments (now the number of paid invoices) are counted
-- differently.

create or replace view public.billing_position with (security_invoker = true) as
select e.auth_id,
       e.client_id,
       c.name as client_name,
       e.auth_number,
       e.service_type,
       e.status,
       e.authorized,
       e.invoiced,
       coalesce(i.paid, 0::numeric) as paid,
       coalesce(i.outstanding, 0::numeric) as outstanding,
       greatest(e.authorized - e.invoiced, 0::numeric) as not_yet_invoiced,
       i.last_paid_on,
       coalesce(i.paid_invoices, 0::bigint) as payments
  from public.authorization_economics e
  join public.clients c on c.id = e.client_id
  left join (
    select inv.auth_id,
           sum(inv.amount) filter (where inv.status = 'Paid') as paid,
           sum(inv.amount) filter (where inv.status = 'Sent') as outstanding,
           max(inv.paid_date) filter (where inv.status = 'Paid') as last_paid_on,
           count(*) filter (where inv.status = 'Paid') as paid_invoices
      from public.invoices inv
     group by inv.auth_id
  ) i on i.auth_id = e.auth_id;

grant select on public.billing_position to authenticated;

comment on view public.billing_position is
  'Per authorization: authorized, invoiced (not Void), paid (invoices marked Paid), outstanding (invoices Sent, not yet paid), not yet invoiced. Shown on Billing → Invoices.';

-- ── screen hints follow their screens ──────────────────────
-- Admin's nine screens are three pages, Revenue and Referrals are in Insights.
-- Hints on the same page show one at a time: dismissing one brings the next.
update public.tour_hints set screen = '/admin/people'     where key in ('staff', 'contractors');
update public.tour_hints set screen = '/admin/documents'  where key in ('document-inbox', 'retention', 'records-request');
update public.tour_hints set screen = '/admin/system'     where key in ('settings', 'access-log', 'exports');
update public.tour_hints set screen = '/insights/money'   where key = 'revenue';
update public.tour_hints set screen = '/insights/referrals' where key = 'referrals';

update public.tour_hints set body =
  'Your tasks due today or before, the alerts raised overnight, and five counters for what might need somebody today — each opens its list. Connect Outlook here, and start a work session if you log hours. "+ Add" at the top right writes a note, task, job, interview, placement or work session from wherever you are.'
 where key = 'dashboard';

update public.tour_hints set body =
  'Money in four figures: authorized and not yet earned, earned and not yet invoiced, invoiced and not yet paid, and received. Hourly work earns by the hour; a flat fee earns on completion, so a flat fee with hours against it and no completion recorded has earned nothing. "Worth watching" is the part to read — quiet authorizations, ones about to expire, and anything a USOR form is blocking. Paid and outstanding per client is on Billing → Invoices.'
 where key = 'revenue';

update public.tour_hints set title = 'Authorizations, hours, invoices and forms', body =
  'Hours cannot exceed what USOR authorized and an invoice cannot be sent until the forms USOR requires are complete. Both rules are enforced in the database, not by remembering. Invoices also holds the warrant lines waiting for review and what each client has been paid and still owes. The rate schedule is in Admin → System.'
 where key = 'billing';
