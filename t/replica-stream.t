use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use JMAP::Sync::Common;
use Mail::IMAPTalk;
{
  package StreamIMAP;
  sub examine {$_[0]{examined}=$_[1];1}
  sub get_response_code {$_[0]{validity}//9}
  sub literal_handle_control {$_[0]{literal}=$_[1]}
  sub get_last_error {undef}
  sub capability { {unselect=>1} }
  sub unselect {$_[0]{unselected}++;1}
  sub release_socket {$_[0]{released}++;undef}
  sub fetch {
    my ($self,$mode,$uid,$command)=@_;
    die 'must use non-marking streaming command' unless $command eq 'body.peek[]' && $mode->{FullBody};
    return {} if $self->{missing};
    return {$uid=>{'body[]'=>$self->{bytes}}} if $self->{quoted};
    my $f=$self->{literal}->(length($self->{bytes}), 'BODY[]');
    print {$f} $self->{bytes} or die $!;
    return {$uid=>{'body[]'=>$f}};
  }
  package StreamTransport;
  use parent 'JMAP::Sync::Common';
  sub connect_imap {$_[0]{imap}}
}
sub transport {bless {imap=>bless({bytes=>"test\r\n",@_},'StreamIMAP')},'StreamTransport'}
for my $quoted (0,1) {
  my $t=transport(quoted=>$quoted);my ($f)=tempfile();binmode $f;
  is_deeply($t->imap_stream_raw('INBOX',9,10,6,$f),{bytes=>6},$quoted?'small quoted body supported':'literal streams to file');
  seek($f,0,0);is(do {local $/;<$f>},"test\r\n",'octets unchanged');
  is($t->{imap}{literal},0,'stream callback removed on success');
  is($t->{imap}{unselected},1,'mailbox closed read-only');
}
for my $case ([validity=>10,qr/UIDVALIDITY/],[bytes=>'longer than expected',qr/Unexpected replica literal/],[missing=>1,qr/UID disappeared/]) {
  my ($key,$value,$error)=@$case;my $t=transport($key=>$value);my $imap=$t->{imap};my ($f)=tempfile();
  eval {$t->imap_stream_raw('INBOX',9,10,6,$f)};
  like($@,$error,'invalid source is explicit failure');
  ok(!exists($t->{imap}),'interrupted protocol connection discarded');
  is($imap->{literal},0,'stream callback removed on failure');
}
my $body='literal';
my $parsed=Mail::IMAPTalk::_parse_fetch_result(['BODY[]',$body],{FullBody=>1});
is($parsed->{'body[]'},$body,'installed IMAP library preserves selected full-body response key');
done_testing;
