use strict;
use warnings;
use Test::More;
use JSON::XS qw(decode_json);
use Digest::SHA qw(sha256_hex);
BEGIN {
  require File::Temp;
  $ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);
  $ENV{JMAP_SECRET_KEY}='f' x 64;
}
use JMAP::ImapDB;
use JMAP::Delivery;
my $db=JMAP::ImapDB->new('audit');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$db->begin();$db->dmake('jmessages',{msgid=>'m1',thrid=>'t1',keywords=>'{}'});
$db->dinsert('jrawmessage',{msgid=>'m1',hasAttachment=>0});$db->commit();
$db->write_parsed_msg('m1',{id=>'m1',preview=>'synthetic private content'});
sub check {
  open my $f,'-|',$^X,'bin/check-mail-cache.pl','--data-dir',$ENV{JMAP_DATADIR},'--account','audit' or die $!;
  my $text=do {local $/;<$f>};close $f;
  return (decode_json($text),$?>>8,$text);
}
my ($r,$exit,$text)=check();
is($exit,0,'consistent parsed cache audit succeeds');
is($r->{parsed}{valid},1,'cached file checked against catalog');
unlike($text,qr/synthetic private content|password/,'audit output does not contain message contents');
my $file="$ENV{JMAP_DATADIR}/audit/parsed/m1.json";
open my $f,'<:raw',$file;my $before=do {local $/;<$f>};close $f;
$db->write_subdir('parsed','m1.json','{"incomplete":');
($r,$exit)=check();
is($exit,2,'invalid file produces non-success audit');
is($r->{parsed}{invalid},1,'invalid cached JSON is counted');
open $f,'<:raw',$file;is(do {local $/;<$f>},'{"incomplete":','audit does not repair or remove evidence');close $f;
$db->write_subdir('parsed','m1.json',$before);
my $p=JMAP::Delivery->prepare($db,msgid=>'m1',thrid=>'t1',envelope=>{},message=>'private MIME',sendat=>1,held=>1);
($r,$exit)=check();is($exit,0,'prepared outbox hash verified');
$db->write_subdir('outbox',"$p->{jsubid}.eml",'wrong MIME');
($r,$exit)=check();
is($r->{outbox}{hash_mismatch},1,'outbox manifest detects mismatching bytes');
is($exit,2,'mismatching outbox does not pass audit');
done_testing;
