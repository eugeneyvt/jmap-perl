use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha256_hex);
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='e'x64}
use JMAP::ImapDB;
use JMAP::Replica;
use JMAP::ReplicaParser;
use JMAP::ReplicaContent;
use JMAP::FileResponse;
my $dir=abs_path(tempdir(CLEANUP=>1));mkdir "$dir/box";mkdir "$dir/spool";
my $binary="binary\0bytes\r\n"x100000;
my $raw="Subject: Multipart fixture\r\nFrom: Test <sender\@example.invalid>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=x\r\n\r\n".
  "--x\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nText=20part\r\n".
  "--x\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=fixture.bin\r\nContent-Transfer-Encoding: base64\r\n\r\n".
  encode_base64($binary)."\r\n--x--\r\n";
open my $f,'>:raw',"$dir/raw";print {$f} $raw;close $f;
my $parsed=JMAP::ReplicaParser->parse("$dir/raw",spool=>"$dir/spool",msgid=>'stable');
my $native=Data::JSEmail::parse($raw,'stable');
for my $property (qw(textBody htmlBody attachments bodyValues)) {
  is_deeply($parsed->{parsed}{$property},$native->{$property},"multipart native $property contract");
}
my $db=JMAP::ImapDB->new('content');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
mkdir "$ENV{JMAP_DATADIR}/content";
my $replica=JMAP::Replica->new(path=>"$ENV{JMAP_DATADIR}/content/replica.sqlite3");
$replica->enqueue({msgid=>'stable',folder=>1,uidvalidity=>1,uid=>1,bytes=>length($raw)});
my $job=$replica->claim;
my $available=1;my $calls=0;
my $store=JMAP::RawStore->new(root=>"$dir/box",account=>'content',guard=>sub {$calls++;$available});
my $manifest=$store->publish("$dir/raw",length($raw));
$replica->raw_saved($job,$manifest);$replica->complete($job,$parsed);
{
  no warnings 'redefine';
  local *JMAP::StorageBox::from_env=sub {$store};
  my $original=JMAP::ReplicaContent->download($db,'m-stable');
  is($original->{bytes},length($raw),'cold original length');
  my ($original_hash)=JMAP::RawStore->digest_file($original->{file});
  is($original_hash,sha256_hex($raw),'cold original byte-exact');
  $available=0;my $before=$calls;
  my $attachment=JMAP::ReplicaContent->download($db,'m-stable-2');
  is($attachment->{bytes},length($binary),'attachment decoded byte length');
  my ($hash)=JMAP::RawStore->digest_file($attachment->{file});
  is($hash,sha256_hex($binary),'binary attachment decoded without changing octets');
  is($calls,$before,'hot raw produces attachments with no Box access');
  my ($length,$body)=JMAP::FileResponse->prepare($JMAP::DB::DATADIR,'content',$attachment);
  my $sha=Digest::SHA->new(256);
  for (1..100) {$body->(sub {$sha->add($_[0])})}
  is($sha->hexdigest,sha256_hex($binary),'HTTP streamed attachment has exact checksum');$body->(undef);
  eval {JMAP::ReplicaContent->download($db,'m-stable-99')};like($@,qr/attachment not found/,'invalid part fails explicitly');
}
done_testing;
