/**
 * A voicemail is a kind of file a client can have (owner, 27 November 2026).
 *
 * `attachments.category` is a foreign key to `client_file_categories`, so
 * 0395's `file_voicemail` would have raised on the first real message: there
 * was no such category to file one under. The verify script found it before
 * a client ever rang.
 *
 * Its own category rather than 'Recording', because a client's files are read
 * by people deciding what to do next, and "a meeting somebody recorded" and
 * "a message on the answerphone" are two different things to find on a list.
 *
 * **Restricted, like any audio.** Not a choice made here: a trigger sets
 * `restricted` on every audio attachment whatever the form said
 * (`verify_recordings` asserts it), and this row agrees with the trigger
 * rather than being quietly overruled by it. The reason is the thing itself -
 * it is a recording of somebody's voice talking about their own life.
 *
 * The words are a separate question and they are **not** restricted: the
 * transcript goes on the contact-log line, where anybody who can see the
 * client can read it. That is what the owner asked for - a voicemail has to
 * reach the client threads board and the needs-reply count as something
 * somebody can act on, and "a message, not read yet" is a row somebody has
 * to go and open. So the audio is restricted and the sentence is not, which
 * is a widening worth saying out loud rather than discovering.
 *
 * Tolerates the old code: one row in a lookup table. Nothing that exists is
 * filed under it, and nothing deployed can file anything under it yet.
 */

insert into public.client_file_categories (key, label, detail, restricted_by_default, sort_order, active)
values ('Voicemail', 'Voicemail',
        'A message left on the practice line, with what it said.',
        true, 25, true)
on conflict (key) do update
   set label = excluded.label,
       detail = excluded.detail,
       restricted_by_default = excluded.restricted_by_default,
       active = true;

do $$
declare r record;
begin
  select * into r from public.client_file_categories where key = 'Voicemail';
  if r.key is null then
    raise exception 'there is still no category to file a voicemail under';
  end if;
  if not r.restricted_by_default then
    raise exception 'a voicemail would be filed unrestricted, and the audio trigger would overrule it';
  end if;
  if not r.active then
    raise exception 'the voicemail category is switched off, so nothing could be filed under it';
  end if;

  raise notice 'ok  a voicemail has a category of its own, restricted like any audio';
end $$;
