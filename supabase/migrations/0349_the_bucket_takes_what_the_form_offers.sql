-- Zion Vocational Rehab CRM — the bucket takes what the form offers
--
-- Found by trying it. The live test of item F put a WAV recording on the
-- fixture client and storage refused it: "mime type audio/wav is not
-- supported". The recording never reached the record, so nothing was queued
-- and nothing was read.
--
-- 0342 widened the bucket for the phone, and widened it to exactly what a
-- phone browser records in - webm, mp4, mpeg, ogg, aac, x-m4a. Item F then
-- added eight extensions to the client record's file picker, .wav and .flac
-- among them, and did not widen the bucket with them. So the form offered a
-- file type the storage layer refused, and a handheld recorder - which is
-- what a WAV comes from - was offered and then turned away.
--
-- The fix is the bucket, not the form: a dictation recorder writes WAV, Azure
-- Speech reads WAV better than anything else, and a member of staff holding a
-- recorder should not have to convert a file to put it on a record.
--
-- The aliases are here because the browser chooses the string, not us, and
-- storage compares it exactly. Windows reports a .wav as audio/wav,
-- audio/x-wav or audio/wave depending on what is in the registry; .flac and
-- .m4a and .mp3 have the same spread. Granting one spelling and refusing
-- another would be the same bug on a different machine.
--
-- scripts/check-upload-types.mjs now asks the question this answers: every
-- extension the file picker offers has every mime type a browser sends for it
-- granted on the bucket. It runs in prebuild, so the next person to add an
-- extension finds out at the build rather than on a client record.

begin;

update storage.buckets
   set allowed_mime_types = (
     select array_agg(distinct m order by m)
       from unnest(allowed_mime_types || array[
         -- .wav, from a handheld recorder or a desktop dictation app
         'audio/wav', 'audio/x-wav', 'audio/wave', 'audio/vnd.wave',
         -- .flac, from a recorder set to lossless
         'audio/flac', 'audio/x-flac',
         -- spellings of what 0342 already took, from machines that say it
         -- differently
         'audio/mp3', 'audio/m4a'
       ]) as m)
 where id = 'client-files';

commit;
