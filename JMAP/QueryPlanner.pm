package JMAP::QueryPlanner;
use strict;
use warnings;
use Date::Parse qw(str2time);
use JMAP::Collation;
use JSON::XS;

# Compile predicates over the account's complete active-message universe. A
# mailbox restricts candidates, never the universe of a thread-wide predicate.
# Unhandled inputs return undef before any provider I/O or database mutation.
sub compile {
  my ($class, $args, $idmap) = @_;
  my $self = bless {terms=>[], idmap=>$idmap, filter_binds=>[], sort_binds=>[]}, $class;
  my $where = $self->_filter($args->{filter});
  return unless defined $where;
  my (@columns, @order);
  my %number = (receivedAt=>'internaldate', sentAt=>'msgdate', size=>'msgsize');
  my %string = (id=>'msgid', subject=>'sortsubject', from=>'msgfrom', to=>'msgto');
  my $i = 0;
  for my $arg (@{$args->{sort} || []}) {
    my $property = $arg->{property} // '';
    my ($expression, $collation);
    if ($number{$property}) { $expression = "COALESCE(m.$number{$property},0)" }
    elsif ($string{$property}) {
      my $name = $arg->{collation} // $JMAP::Collation::DEFAULT;
      return unless JMAP::Collation::is_supported($name);
      $name =~ s/[^a-z0-9]/_/g;
      $collation = ' COLLATE jmap_' . $name;
      $expression = "COALESCE(m.$string{$property},'')";
    }
    elsif ($property eq 'hasKeyword') {
      $expression = 'jmap_keyword(m.keywords,?)';
      push @{$self->{sort_binds}}, $arg->{keyword} // '';
    }
    elsif ($property eq 'allInThreadHaveKeyword' || $property eq 'someInThreadHaveKeyword') {
      my $all = $property eq 'allInThreadHaveKeyword';
      $expression = ($all ? 'NOT ' : '') . "EXISTS(SELECT 1 FROM jmessages t
        WHERE t.active=1 AND COALESCE(t.thrid,'')=COALESCE(m.thrid,'')
        AND jmap_keyword(t.keywords,?)=" . ($all ? '0' : '1') . ')';
      push @{$self->{sort_binds}}, $arg->{keyword} // '';
    }
    else { return }
    push @columns, "$expression AS sk$i";
    my $direction = defined($arg->{isAscending}) && !$arg->{isAscending} ? 'DESC' : 'ASC';
    push @order, "sk$i" . ($collation // '') . " $direction";
    $i++;
  }
  push @order, 'msgid COLLATE BINARY ASC';
  my $order = join(',', @order);
  my $projection = join(',', 'm.msgid', 'm.thrid', @columns);
  my $required=$self->_required_terms($args->{filter});
  my ($first)=sort {$a<=>$b} keys %$required;
  my ($mailbox)=sort keys %{$self->_required_mailboxes($args->{filter})};
  my (@driver_binds,$from,$restrict);
  if (defined $first) {
    $from='temp.jmap_provider_hits ph CROSS JOIN jmessages m ON m.msgid=ph.msgid';
    $restrict="ph.term=$first AND ";
  }
  elsif (defined $mailbox) {
    $self->{driving_mailbox}=$mailbox;
    $self->{filter_binds}=[];
    $where=$self->_filter($args->{filter});
    $from='jmessagemap member INDEXED BY jemailmembership CROSS JOIN jmessages m ON m.msgid=member.msgid';
    $restrict='member.active=1 AND member.jmailboxid=? AND ';
    @driver_binds=($mailbox);
  }
  else {$from='jmessages m';$restrict=''}
  my $sql = "WITH candidates AS(SELECT $projection FROM $from WHERE ${restrict}m.active=1 AND ($where))";
  if ($args->{collapseThreads}) {
    $sql .= ", representatives AS(SELECT *,ROW_NUMBER() OVER(PARTITION BY COALESCE(thrid,'') ORDER BY $order) AS representative FROM candidates)";
    $sql .= " SELECT ROW_NUMBER() OVER(ORDER BY $order)-1 AS position,msgid FROM representatives WHERE representative=1";
  }
  else { $sql .= " SELECT ROW_NUMBER() OVER(ORDER BY $order)-1 AS position,msgid FROM candidates" }
  $self->{sql} = $sql;
  $self->{binds} = [@{$self->{sort_binds}}, @driver_binds, @{$self->{filter_binds}}];
  delete $self->{idmap};
  return $self;
}

# Only a logically necessary positive provider term may narrow the candidate
# universe. OR intersects necessities; NOT never narrows it. Thread predicates
# continue to use the complete jmessages universe in their correlated subquery.
sub _required_values {
  my ($self,$filter,$leaf)=@_;
  return {} unless ref($filter) eq 'HASH';
  if ($filter->{operator}) {
    return {} if $filter->{operator} eq 'NOT';
    my @sets=map {$self->_required_values($_,$leaf)} @{$filter->{conditions}};
    return {} unless @sets;
    my %terms=%{shift @sets};
    for my $set (@sets) {
      if ($filter->{operator} eq 'AND') {$terms{$_}=1 for keys %$set}
      else {delete $terms{$_} for grep {!$set->{$_}} keys %terms}
    }
    return \%terms;
  }
  return $leaf->($filter);
}

sub _required_terms {
  my ($self,$filter)=@_;
  return $self->_required_values($filter,sub {
    my ($f)=@_;my %terms;
    for my $key (qw(text from to cc bcc subject body header)) {
      next unless $f->{$key};
      my @search=$key eq 'header' ? ($key,@{$f->{$key}}) : ($key,$f->{$key});
      push @search,'' if $key eq 'header' && @search==2;
      my $index=$self->{term_map}{JSON::XS->new->canonical->encode(\@search)};
      $terms{$index}=1 if defined $index;
    }
    return \%terms;
  });
}

sub _required_mailboxes {
  my ($self,$filter)=@_;
  return $self->_required_values($filter,sub {
    my ($f)=@_;
    return $f->{inMailbox} ? {$self->{idmap}->($f->{inMailbox})=>1} : {};
  });
}

sub _filter {
  my ($self, $filter) = @_;
  return '1' unless defined $filter;
  return unless ref($filter) eq 'HASH';
  if (exists $filter->{operator}) {
    return unless keys(%$filter) == 2 && ref($filter->{conditions}) eq 'ARRAY';
    my $op = $filter->{operator};
    return unless $op =~ /^(?:AND|OR|NOT)$/;
    my @parts;
    for my $f (@{$filter->{conditions}}) {
      my $part = $self->_filter($f);
      return unless defined $part;
      push @parts, "($part)";
    }
    my $joined = @parts ? join($op eq 'AND' ? ' AND ' : ' OR ', @parts) : ($op eq 'AND' ? '1' : '0');
    return $op eq 'NOT' ? "NOT($joined)" : $joined;
  }
  my @parts;
  for my $key (sort keys %$filter) {
    my $value = $filter->{$key};
    # Match the legacy truthy checks, including ignored empty search strings.
    next unless $value || $key eq 'hasAttachment';
    if ($key eq 'inMailbox') {
      next if defined($self->{driving_mailbox}) && $self->{idmap}->($value) eq $self->{driving_mailbox};
      push @parts, 'EXISTS(SELECT 1 FROM jmessagemap mm WHERE mm.msgid=m.msgid AND mm.active=1 AND mm.jmailboxid=?)';
      push @{$self->{filter_binds}}, $self->{idmap}->($value);
    }
    elsif ($key eq 'inMailboxOtherThan') {
      my @ids = map { $self->{idmap}->($_) } ref($value) eq 'ARRAY' ? @$value : ($value);
      push @parts, 'EXISTS(SELECT 1 FROM jmessagemap mm WHERE mm.msgid=m.msgid AND mm.active=1' .
        (@ids ? ' AND mm.jmailboxid NOT IN(' . join(',', ('?') x @ids) . ')' : '') . ')';
      push @{$self->{filter_binds}}, @ids;
    }
    elsif ($key eq 'before' || $key eq 'after') {
      my $time = str2time($value); return unless defined $time;
      push @parts, 'COALESCE(m.internaldate,0)' . ($key eq 'before' ? '<' : '>=') . 'CAST(? AS REAL)';
      push @{$self->{filter_binds}}, $time;
    }
    elsif ($key eq 'minSize' || $key eq 'maxSize') {
      push @parts, 'COALESCE(m.msgsize,0)' . ($key eq 'minSize' ? '>=' : '<') . 'CAST(? AS REAL)';
      push @{$self->{filter_binds}}, 0+$value;
    }
    elsif ($key eq 'hasKeyword' || $key eq 'notKeyword') {
      push @parts, 'jmap_keyword(m.keywords,?)=' . ($key eq 'hasKeyword' ? '1' : '0');
      push @{$self->{filter_binds}}, $value;
    }
    elsif ($key =~ /^(all|some|none)InThreadHaveKeyword$/) {
      my $kind = $1;
      push @parts, ($kind eq 'some' ? '' : 'NOT ') . "EXISTS(SELECT 1 FROM jmessages t
        WHERE t.active=1 AND COALESCE(t.thrid,'')=COALESCE(m.thrid,'') AND jmap_keyword(t.keywords,?)=" .
        ($kind eq 'all' ? '0' : '1') . ')';
      push @{$self->{filter_binds}}, $value;
    }
    elsif ($key eq 'hasAttachment') {
      push @parts, ($value ? '' : 'NOT ') . 'EXISTS(SELECT 1 FROM jrawmessage r WHERE r.msgid=m.msgid AND r.hasAttachment=1)';
    }
    elsif ($key =~ /^(?:text|from|to|cc|bcc|subject|body|header)$/) {
      my @search = $key eq 'header' ? ($key, @$value) : ($key, $value);
      push @search, '' if $key eq 'header' && @search == 2;
      my $termkey=JSON::XS->new->canonical->encode(\@search);
      my $term=$self->{term_map}{$termkey};
      unless (defined $term) {
        $term=@{$self->{terms}};
        $self->{term_map}{$termkey}=$term;
        push @{$self->{terms}}, \@search;
      }
      push @parts, "EXISTS(SELECT 1 FROM temp.jmap_provider_hits h WHERE h.term=$term AND h.msgid=m.msgid)";
    }
    else { return }
  }
  return @parts ? join(' AND ', @parts) : '1';
}
1;
