package JMAP::ReplicaParser;
use strict;
use warnings;
use MIME::Parser;
use File::Temp;
use Encode qw(decode FB_CROAK);
use HTML::Strip;
use Data::JSEmail;
use Email::MIME;
use JSON;

# MIME binary parts stay in private temporary files. Limit parts and extracted
# text separately: a large binary attachment must not become a Perl string.
sub parse {
  my ($class,$path,%args)=@_;
  my $temporary=File::Temp->newdir('jmap-mime-XXXXXXXX',DIR=>$args{spool},CLEANUP=>1);
  my $work="$temporary";
  chmod(0700,$work) or die "Cannot protect MIME spool\n";
  my $parser=MIME::Parser->new;
  $parser->output_under($work);$parser->tmp_dir($work);
  $parser->output_to_core(0);$parser->tmp_to_core(0);$parser->max_parts(1000);
  $parser->extract_nested_messages(0);
  $parser->ignore_errors(0);
  # MIME-tools normally normalizes 7bit/8bit line endings. Preserve decoded
  # octet sizes/attachment bytes, then normalize only JMAP text bodyValues.
  my $entity;
  {
    local $MIME::Decoder::DecoderFor{'7bit'}='MIME::Decoder::Binary';
    local $MIME::Decoder::DecoderFor{'8bit'}='MIME::Decoder::Binary';
    $entity=$parser->parse_open($path) or die "MIME parse failed\n";
  }
  my $budget=$args{max_text_bytes}//16*1024*1024;
  my %doc;
  for my $field ([subject=>'Subject'],[sender=>'From'],[recipients=>'To'],[cc=>'Cc'],[bcc=>'Bcc']) {
    my $value=$entity->head->get($field->[1])//'';
    $doc{$field->[0]}=_header($value);
  }
  my (@body,@names);my @todo=($entity);my $used=0;
  while (my $part=shift @todo) {
    my @parts=$part->parts;
    if (@parts) {unshift @todo,@parts;next}
    my $name=$part->head->recommended_filename;
    push @names,_header($name) if defined($name) && length($name);
    # Attached text files are attachments, not a mail body. Attachment content
    # indexing/OCR is deliberately outside the current search contract.
    next if ($part->head->mime_attr('content-disposition')//'') =~ /^attachment/i;
    next unless $part->effective_type =~ m{^text/(plain|html)$}i;
    my $html=lc($1) eq 'html';
    my $handle=$part->bodyhandle or next;
    my $f=$handle->open('r') or die "MIME text unavailable\n";
    my $text='';
    while (1) {
      my $n=$f->read(my $buf,65536);die "MIME text read failed\n" unless defined $n;last unless $n;
      $used+=$n;die "MIME text budget exceeded\n" if $used>$budget;
      $text.=$buf;
    }
    $f->close;
    my $charset=$part->head->mime_attr('content-type.charset')//'UTF-8';
    # Corrupt/unknown charset is a visible parse failure; do not mark lossy or
    # truncated search text as a complete document.
    $text=decode($charset,$text,FB_CROAK);
    if ($html) {
      $text =~ s{<(script|style)\b[^>]*>.*?</\1\s*>}{ }gis;
      $text=HTML::Strip->new->parse($text);
    }
    push @body,$text;
  }
  $doc{body}=join("\n",@body);$doc{body}=~s/\s+/ /g;
  $doc{attachments}=join("\n",@names);
  if (defined $args{msgid}) {
    my $head=Email::MIME->new($entity->head->as_string."\r\n");
    my $parsed={id=>$args{msgid},headers=>Data::JSEmail::headers($head)};
    for my $field ([sender=>'Sender'],[from=>'From'],[to=>'To'],[cc=>'Cc'],[bcc=>'Bcc'],[replyTo=>'Reply-To']) {
      $parsed->{$field->[0]}=Data::JSEmail::asAddresses($head->header($field->[1]));
    }
    for my $field ([messageId=>'Message-Id'],[references=>'References'],[inReplyTo=>'In-Reply-To']) {
      $parsed->{$field->[0]}=Data::JSEmail::asMessageIds($head->header($field->[1]));
    }
    $parsed->{subject}=Data::JSEmail::asText($head->header('Subject'));
    $parsed->{sentAt}=Data::JSEmail::asDate($head->header('Date'));
    my (%values,@text,@html,@attachments);
    my $bytes=0;
    my $tree=_node($entity,'',$args{msgid},\%values,\$bytes,$budget);
    Data::JSEmail::parseStructure([$tree],'mixed',0,\@text,\@html,\@attachments);
    $parsed->{bodyStructure}=$tree;$parsed->{bodyValues}=\%values;
    $parsed->{textBody}=\@text;$parsed->{htmlBody}=\@html;$parsed->{attachments}=\@attachments;
    my ($has)=grep {($_->{disposition}//'') ne 'inline'} @attachments;
    $parsed->{hasAttachment}=$has?$JSON::true:$JSON::false;
    $parsed->{preview}=substr($doc{body},0,256);$parsed->{size}=-s $path;
    $doc{parsed}=$parsed;
  }
  return \%doc;
}

sub _node {
  my ($entity,$number,$id,$values,$used,$budget)=@_;
  my $headers=Data::JSEmail::headers(Email::MIME->new($entity->head->as_string."\r\n"));
  my @parts=$entity->parts;
  if (@parts) {
    my @nodes;
    for my $index (0..$#parts) {push @nodes,_node($parts[$index],length($number)?"$number.".($index+1):''.($index+1),$id,$values,$used,$budget)}
    return {partId=>undef,blobId=>undef,type=>$entity->effective_type,size=>0,headers=>$headers,
      name=>undef,cid=>undef,charset=>undef,language=>undef,location=>undef,disposition=>undef,subParts=>\@nodes};
  }
  $number||='1';
  my $handle=$entity->bodyhandle;
  my $size=$handle ? -s $handle->path : 0;
  my $type=$entity->effective_type;
  my $charset=$entity->head->mime_attr('content-type.charset');
  if ($type=~m{^text/}i && $handle) {
    $$used+=$size;die "MIME text budget exceeded\n" if $$used>$budget;
    my $text=$handle->as_string;
    $text=decode($charset//'us-ascii',$text,FB_CROAK);$text=~s/\r\n/\n/g;
    $values->{$number}={value=>$text,isEncodingProblem=>$JSON::false,isTruncated=>$JSON::false};
  }
  return {partId=>$number,blobId=>"m-$id-$number",type=>$type,size=>0+$size,headers=>$headers,
    name=>$entity->head->recommended_filename,cid=>Data::JSEmail::asOneURL($entity->head->get('Content-ID')),
    charset=>$charset,language=>Data::JSEmail::asCommaList($entity->head->get('Content-Language')),
    location=>Data::JSEmail::asText($entity->head->get('Content-Location')),
    disposition=>$entity->head->mime_attr('content-disposition')||undef};
}

sub _header {
  my ($value)=@_;
  my $decoded=eval {decode('MIME-Header',$value,FB_CROAK)};
  die "MIME header decode failed\n" unless defined $decoded;
  $decoded =~ s/\s+/ /g;
  return $decoded;
}
1;
