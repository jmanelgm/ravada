package Ravada::VM::KVM;

use warnings;
use strict;

=head1 NAME

Ravada::VM::KVM - KVM Virtual Managers library for Ravada

=cut

use Carp qw(croak carp cluck);
use Data::Dumper;
use Digest::MD5;
use Encode;
use Encode::Locale;
use File::Temp qw(tempfile);
use Fcntl qw(:flock O_WRONLY O_EXCL O_CREAT);
use Hash::Util qw(lock_hash);
use IPC::Run3 qw(run3);
use IO::Interface::Simple;
use JSON::XS;
use LWP::UserAgent;
use Moose;
use Sys::Virt;
use URI;
use XML::LibXML;

use feature qw(signatures);
no warnings "experimental::signatures";

use Ravada::Domain::KVM;
use Ravada::NetInterface::KVM;
use Ravada::NetInterface::MacVTap;

with 'Ravada::VM';

##########################################################################
#

has vm => (
#    isa => 'Sys::Virt'
    is => 'rw'
    ,builder => '_connect'
    ,lazy => 1
);

has type => (
    isa => 'Str'
    ,is => 'ro'
    ,default => 'qemu'
);

#########################################################################3
#

#TODO use config file for DIR_XML
our $DIR_XML = "etc/xml";
$DIR_XML = "/var/lib/ravada/xml/" if $0 =~ m{^/usr/sbin};

our $XML = XML::LibXML->new();

#-----------
#
# global download vars
#
our ($DOWNLOAD_FH, $DOWNLOAD_TOTAL);

our $CONNECTOR = \$Ravada::CONNECTOR;

##########################################################################


sub _connect {
    my $self = shift;

    my $vm;
    confess "undefined host" if !defined $self->host;

    if ($self->host eq 'localhost') {
        $vm = Sys::Virt->new( address => $self->type.":///system" , readonly => $self->readonly);
    } else {
        $vm = Sys::Virt->new( address => $self->type."+ssh"."://".$self->host."/system"
                              ,readonly => $self->mode
                          );
    }
    if ( ! $vm->list_storage_pools ) {
	warn "WARNING: No storage pools creating default\n";
    	$self->_create_default_pool($vm);
    }
    $self->_check_networks($vm);
    return $vm;
}

sub _check_networks {
    my $self = shift;
    my $vm = shift;

    for my $net ($vm->list_all_networks) {
        next if $net->is_active;

        warn "INFO: Activating KVM network ".$net->get_name."\n";
        $net->create;
        $net->set_autostart(1);
    }
}

=head2 disconnect

Disconnect from the Virtual Machine Manager

=cut

sub disconnect {
    my $self = shift;

    $self->vm(undef);
}

=head2 connect

Connect to the Virtual Machine Manager

=cut

sub connect {
    my $self = shift;
    return if $self->vm;

    $self->vm($self->_connect);
#    $self->storage_pool($self->_load_storage_pool);
}

sub _load_storage_pool {
    my $self = shift;

    my $vm_pool;
    my $available;

    for my $pool ($self->vm->list_storage_pools) {
        my $info = $pool->get_info();
        next if defined $available
                && $info->{available} <= $available
                && !( defined $self->default_storage_pool_name
                        && $pool->get_name eq $self->default_storage_pool_name);

        my $doc = $XML->load_xml(string => $pool->get_xml_description);

        my ($path) =$doc->findnodes('/pool/target/path/text()');
        next if !$path;

        $vm_pool = $pool;
        $available = $info->{available};

    }
    die "I can't find /pool/target/path in the storage pools xml\n"
        if !$vm_pool;

    return $vm_pool;

}

=head2 storage_pool

Returns a storage pool usable by the domain to store new volumes.

=cut

sub storage_pool {
    my $self = shift;

    return $self->_load_storage_pool();
}

=head2 search_volume

Searches for a volume in all the storage pools known to the Virtual Manager

Argument: the filenaname;
Returns the volume as a Sys::Virt::StorageGol. If called in array context returns a
list of all the volumes.

    my $iso = $vm->search_volume("debian-8.iso");

    my @disk = $vm->search_volume("windows10-clone.img");

=cut

sub search_volume($self,$file,$refresh=0) {
    return $self->search_volume_re(qr(^$file$),$refresh);
}

=head2 search_volume_path

Searches for a volume in all the storage pools known to the Virtual Manager

Argument: the filenaname;
Returns the path of the volume. If called in array context returns a
list of all the paths to all the matching volumes.

    my $iso = $vm->search_volume("debian-8.iso");

    my @disk = $vm->search_volume("windows10-clone.img");



=cut

sub search_volume_path {
    my $self = shift;
    my @volume = $self->search_volume(@_);

    my @vol2 = map { $_->get_path() if ref($_) } @volume;

    return $vol2[0] if !wantarray;
    return @vol2;
}

=head2 search_volume_re

Searches for a volume in all the storage pools known to the Virtual Manager

Argument: a regular expression;
Returns the volume. If called in array context returns a
list of all the matching volumes.

    my $iso = $vm->search_volume(qr(debian-\d+\.iso));

    my @disk = $vm->search_volume(qr(windows10-clone.*\.img));

=cut

sub search_volume_re($self,$pattern,$refresh=0) {

    confess "'$pattern' doesn't look like a regexp to me ".ref($pattern)
        if !ref($pattern) || ref($pattern) ne 'Regexp';

    my @volume;
    for my $pool ($self->vm->list_storage_pools) {
        $pool->refresh()    if $refresh;
        for my $vol ( $pool->list_all_volumes()) {
            my ($file) = $vol->get_path =~ m{.*/(.*)};
            next if $file !~ $pattern;

            return $vol if !wantarray;
            push @volume,($vol);
        }
    }
    if (!scalar @volume && !$refresh && !$self->readonly
            && time - ($self->{_time_refreshed} or 0) > 60) {
        $self->{_time_refreshed} = time;
        @volume = $self->search_volume_re($pattern,"refresh");
        return $volume[0] if !wantarray && scalar @volume;
    }
    return if !wantarray && !scalar@volume;
    return @volume;
}

=head2 search_volume_path_re

Searches for a volume in all the storage pools known to the Virtual Manager

Argument: a regular expression;
Returns the volume path. If called in array context returns a
list of all the paths of all the matching volumes.

    my $iso = $vm->search_volume(qr(debian-\d+\.iso));

    my @disk = $vm->search_volume(qr(windows10-clone.*\.img));

=cut


sub search_volume_path_re($self, $pattern) {
    my @vol = $self->search_volume_re($pattern);

    return if !wantarray && !scalar @vol;
    return $vol[0]->get_path if !wantarray;

    return map { $_->get_path() if ref($_) } @vol;

}

=head2 dir_img

Returns the directory where disk images are stored in this Virtual Manager

=cut

sub dir_img {
    my $self = shift;

    my $pool = $self->_load_storage_pool();
    $pool = $self->_create_default_pool() if !$pool;
    my $xml = XML::LibXML->load_xml(string => $pool->get_xml_description());

    my $dir = $xml->findnodes('/pool/target/path/text()');
    die "I can't find /pool/target/path in ".$xml->toString
        if !$dir;

    return $dir;
}

sub _create_default_pool {
    my $self = shift;
    my $vm = shift;
    $vm = $self->vm if !$vm;

    my $uuid = Ravada::VM::KVM::_new_uuid('68663afc-aaf4-4f1f-9fff-93684c260942');

    my $dir = "/var/lib/libvirt/images";
    mkdir $dir if ! -e $dir;

    my $xml =
"<pool type='dir'>
  <name>default</name>
  <uuid>$uuid</uuid>
  <capacity unit='bytes'></capacity>
  <allocation unit='bytes'></allocation>
  <available unit='bytes'></available>
  <source>
  </source>
  <target>
    <path>$dir</path>
    <permissions>
      <mode>0711</mode>
      <owner>0</owner>
      <group>0</group>
    </permissions>
  </target>
</pool>"
;
    my $pool = $vm->create_storage_pool($xml);
    $pool->set_autostart(1);

}

=head2 create_domain

Creates a domain.

    $dom = $vm->create_domain(name => $name , id_iso => $id_iso);
    $dom = $vm->create_domain(name => $name , id_base => $id_base);

=cut

sub create_domain {
    my $self = shift;
    my %args = @_;

    $args{active} = 1 if !defined $args{active};

    croak "argument name required"       if !$args{name};
    croak "argument id_owner required"   if !$args{id_owner};
    croak "argument id_iso or id_base required ".Dumper(\%args)
        if !$args{id_iso} && !$args{id_base};

    my $domain;
    if ($args{id_iso}) {
        $domain = $self->_domain_create_from_iso(@_);
    } elsif($args{id_base}) {
        $domain = $self->_domain_create_from_base(@_);
    } else {
        confess "TODO";
    }

    return $domain;
}

=head2 search_domain

Returns true or false if domain exists.

    $domain = $vm->search_domain($domain_name);

=cut

sub search_domain {
    my $self = shift;
    my $name = shift or confess "Missing name";

    $self->connect();
    my @all_domains;
    eval { @all_domains = $self->vm->list_all_domains() };
    confess $@ if $@;

    for my $dom (@all_domains) {
        next if $dom->get_name ne $name;

        my $domain;

        eval {
            $domain = Ravada::Domain::KVM->new(
                domain => $dom
                ,readonly => $self->readonly
                ,_vm => $self
            );
        };
        warn $@ if $@;
        if ($domain) {
            return $domain;
        }
    }
    return;
}


=head2 list_domains

Returns a list of the created domains

  my @list = $vm->list_domains();

=cut

sub list_domains {
    my $self = shift;

    confess "Missing vm" if !$self->vm;
    my @list;
    my @domains = $self->vm->list_all_domains();
    for my $name (@domains) {
        my $domain ;
        my $id;
        $domain = Ravada::Domain::KVM->new(
                          domain => $name
                        ,_vm => $self
        );
        next if !$domain->is_known();
        $id = $domain->id();
        warn $@ if $@ && $@ !~ /No DB info/i;
        push @list,($domain) if $domain && $id;
    }
    return @list;
}

=head2 create_volume

Creates a new storage volume. It requires a name and a xml template file defining the volume

   my $vol = $vm->create_volume(name => $name, name => $file_xml);

=cut

sub create_volume {
    my $self = shift;

    confess "Wrong arrs " if scalar @_ % 2;
    my %args = @_;

    my ($name, $file_xml, $size, $capacity, $allocation, $swap, $path)
        = @args{qw(name xml size capacity allocation swap path)};

    confess "Missing volume name"   if !$name;
    confess "Missing xml template"  if !$file_xml;
    confess "Invalid size"          if defined $size && ( $size == 0 || $size !~ /^\d+$/);
    confess "Capacity and size are the same, give only one of them"
        if defined $capacity && defined $size;

    $capacity = $size if defined $size;
    $allocation = int($capacity * 0.1)+1
        if !defined $allocation && $capacity;

    open my $fh,'<', $file_xml or confess "$! $file_xml";

    my $doc;
    eval { $doc = $XML->load_xml(IO => $fh) };
    die "ERROR reading $file_xml $@"    if $@;

    my $img_file = ($path or $self->_volume_path(@_));
    my ($volume_name) = $img_file =~m{.*/(.*)};
    $doc->findnodes('/volume/name/text()')->[0]->setData($volume_name);
    $doc->findnodes('/volume/key/text()')->[0]->setData($img_file);
    $doc->findnodes('/volume/target/path/text()')->[0]->setData(
                        $img_file);

    if ($capacity) {
        confess "Size '$capacity' too small" if $capacity< 1024*512;
        $doc->findnodes('/volume/allocation/text()')->[0]->setData($allocation);
        $doc->findnodes('/volume/capacity/text()')->[0]->setData($capacity);
    }
    my $vol = $self->storage_pool->create_volume($doc->toString);
    die "volume $img_file does not exists after creating volume "
            .$doc->toString()
            if ! -e $img_file;

    return $img_file;

}

sub _volume_path {
    my $self = shift;

    my %args = @_;
    my $target = $args{target};
    my $dir_img = $self->dir_img();
    my $suffix = ".img";
    $suffix = ".SWAP.img"   if $args{swap};
    my $filename = $args{name};
    $filename .= "-$target" if $target;
    my (undef, $img_file) = tempfile($filename."-XXXX"
        ,DIR => $dir_img
        ,OPEN => 0
        ,SUFFIX => $suffix
    );
    return $img_file;
}

sub _domain_create_from_iso {
    my $self = shift;
    my %args = @_;

    for (qw(id_iso id_owner name)) {
        croak "argument $_ required"
            if !$args{$_};
    }

    die "Domain $args{name} already exists"
        if $self->search_domain($args{name});

    my $vm = $self->vm;
    my $storage = $self->storage_pool;

    my $iso = $self->_search_iso($args{id_iso});

    die "ERROR: Empty field 'xml_volume' in iso_image ".Dumper($iso)
        if !$iso->{xml_volume};

    my $device_cdrom = $self->_iso_name($iso, $args{request});

    my $disk_size;
    $disk_size = $args{disk} if $args{disk};

    my $file_xml =  $DIR_XML."/".$iso->{xml_volume};

    my $device_disk = $self->create_volume(
          name => $args{name}
         , xml => $file_xml
        , size => $disk_size
        ,target => 'vda'
    );

    my $xml = $self->_define_xml($args{name} , "$DIR_XML/$iso->{xml}");

    _xml_modify_cdrom($xml, $device_cdrom);
    _xml_modify_disk($xml, [$device_disk])    if $device_disk;
    $self->_xml_modify_usb($xml);
    _xml_modify_video($xml);

    my $domain = $self->_domain_create_common($xml,%args);
    $domain->_insert_db(name=> $args{name}, id_owner => $args{id_owner});

    return $domain;
}

sub _domain_create_common {
    my $self = shift;
    my $xml = shift;
    my %args = @_;

    $self->_xml_modify_memory($xml,$args{memory})   if $args{memory};
    $self->_xml_modify_network($xml , $args{network})   if $args{network};
    $self->_xml_modify_mac($xml);
    $self->_xml_modify_uuid($xml);
    $self->_xml_modify_spice_port($xml);
    $self->_fix_pci_slots($xml);

    my $dom;

    eval {
        $dom = $self->vm->define_domain($xml->toString());
        $dom->create if $args{active};
    };
    if ($@) {
        my $out;
		warn $@;
        my $name_out = "/var/tmp/$args{name}.xml";
        warn "Dumping $name_out";
        open $out,">",$name_out and do {
            print $out $xml->toString();
        };
        close $out;
        warn "$! $name_out" if !$out;
        die $@ if !$dom;
    }

    my $domain = Ravada::Domain::KVM->new(
              _vm => $self
         , domain => $dom
        , storage => $self->storage_pool
    );

    return $domain;
}

sub _create_disk {
    return _create_disk_qcow2(@_);
}

sub _create_swap_disk {
    return _create_disk_raw(@_);
}

sub _create_disk_qcow2 {
    my $self = shift;
    my ($base, $name) = @_;

    confess "Missing base" if !$base;
    confess "Missing name" if !$name;

    my $dir_img  = $self->dir_img;

    my @files_out;

    for my $file_data ( $base->list_files_base_target ) {
        my ($file_base,$target) = @$file_data;
        my $ext = ".qcow2";
        $ext = ".SWAP.qcow2" if $file_base =~ /\.SWAP\.ro\.\w+$/;
        my $file_out = "$dir_img/$name-".($target or _random_name(2))
            ."-"._random_name(2).$ext;

        my @cmd = ('qemu-img','create'
                ,'-f','qcow2'
                ,"-b", $file_base
                ,$file_out
        );
#    warn join(" ",@cmd)."\n";

        my ($in, $out, $err);
        run3(\@cmd,\$in,\$out,\$err);
#        print $out  if $out;
#        warn $err   if $err;

        if (! -e $file_out) {
            warn "ERROR: Output file $file_out not created at ".join(" ",@cmd)."\n$err\n$out\n";
            exit;
        }
        push @files_out,($file_out);
    }
    return @files_out;

}

sub _create_disk_raw {
    my $self = shift;
    my ($base, $name) = @_;

    confess "Missing base" if !$base;
    confess "Missing name" if !$name;

    my $dir_img  = $self->dir_img;

    my @files_out;

    for my $file_base ( $base->list_files_base ) {
        next unless $file_base =~ /SWAP\.img$/;
        my $file_out = $file_base;
        $file_out =~ s/\.ro\.\w+$//;
        $file_out =~ s/-.*(img|qcow\d?)//;
        $file_out .= ".$name-".Ravada::Utils::random_name(4).".SWAP.img";

        push @files_out,($file_out);
    }
    return @files_out;

}

sub _random_name { return Ravada::Utils::random_name(@_); };

sub _search_domain_by_id {
    my $self = shift;
    my $id = shift;

    my $sth = $$CONNECTOR->dbh->prepare("SELECT * FROM domains WHERE id=?");
    $sth->execute($id);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    return $self->search_domain($row->{name});
}

sub _domain_create_from_base {
    my $self = shift;
    my %args = @_;

    confess "argument id_base or base required ".Dumper(\%args)
        if !$args{id_base} && !$args{base};

    die "Domain $args{name} already exists"
        if $self->search_domain($args{name});

    my $base = $args{base};

    $base = $self->_search_domain_by_id($args{id_base}) if $args{id_base};
    confess "Unknown base id: $args{id_base}" if !$base;

    my $vm = $self->vm;
    my $storage = $self->storage_pool;

    my $xml = XML::LibXML->load_xml(string => $base->get_xml_base());


    my @device_disk = $self->_create_disk($base, $args{name});
    $self->storage_pool->refresh();
#    _xml_modify_cdrom($xml);
    _xml_remove_cdrom($xml);
    my ($node_name) = $xml->findnodes('/domain/name/text()');
    $node_name->setData($args{name});

    _xml_modify_disk($xml, \@device_disk);#, \@swap_disk);

    my $domain = $self->_domain_create_common($xml,%args);
    $domain->_insert_db(name=> $args{name}, id_base => $base->id, id_owner => $args{id_owner});
    return $domain;
}

sub _fix_pci_slots {
    my $self = shift;
    my $doc = shift;

    my %dupe = ("0x01/0x1" => 1); #reserved por IDE PCI
    my ($all_devices) = $doc->findnodes('/domain/devices');

    for my $dev ($all_devices->findnodes('*')) {

        # skip IDE PCI, reserved before
        next if $dev->getAttribute('type')
            && $dev->getAttribute('type') eq 'ide';

#        warn "finding address of type ".$dev->getAttribute('type')."\n";

        for my $child ($dev->findnodes('address')) {
            my $bus = $child->getAttribute('bus');
            my $slot = $child->getAttribute('slot');
            next if !defined $slot;
            next if !$dupe{"$bus/$slot"}++;

            my $new_slot = $slot;
            for (;;) {
                last if !$dupe{"$bus/$new_slot"};
                my ($n) = $new_slot =~ m{x(\d+)};
                $n++;
                $n= "0$n" if length($n)<2;
                $new_slot="0x$n";
            }
            $dupe{"$bus/$new_slot"}++;
            $child->setAttribute(slot => $new_slot);
        }
    }

}

sub _iso_name {
    my $self = shift;
    my $iso = shift;
    my $req = shift;

    my ($iso_name) = $iso->{url} =~ m{.*/(.*)};
    $iso_name = $iso->{url} if !$iso_name;

    my $device = ($iso->{device} or $self->dir_img."/$iso_name");

    confess "Missing MD5 field on table iso_images FOR $iso->{url}"
        if !$iso->{md5};

    my $downloaded = 0;
    if (! -e $device || ! -s $device) {
        $req->status("downloading $iso_name file"
                ,"Downloading ISO file for $iso_name "
                 ." from $iso->{url}. It may take several minutes"
        )   if $req;
        _download_file_external($iso->{url}, $device);
        die "Download failed, file $device missing.\n"
            if ! -e $device;
        die "Download failed, MD5 id=$iso->{id} missmatched for $device."
        ." Please read ISO "
        ." MD5 missmatch at operation docs.\n"
            if (! _check_md5($device, $iso->{md5}));

        $req->status("done","File $iso->{filename} downloaded") if $req;
        $downloaded = 1;
    }
    if ($downloaded || !$iso->{device} ) {
        my $sth = $$CONNECTOR->dbh->prepare(
                "UPDATE iso_images SET device=? WHERE id=?"
        );
        $sth->execute($device,$iso->{id});
    }
    return $device;
}

sub _check_md5 {
    my ($file, $md5 ) =@_;

    my  $ctx = Digest::MD5->new;
    open my $in,'<',$file or die "$! $file";
    $ctx->addfile($in);

    my $digest = $ctx->hexdigest;

    return 1 if $digest eq $md5;

    warn "$file MD5 fails\n"
        ." got  : $digest\n"
        ."expecting: $md5\n"
        ;
    return 0;
}

sub _download_file_lwp_progress {
    my( $data, $response, $proto ) = @_;
    print $DOWNLOAD_FH $data; # write data to file
    $DOWNLOAD_TOTAL += length($data);
    my $size = $response->header('Content-Length');
    warn floor(($DOWNLOAD_TOTAL/$size)*100),"% downloaded\n"; # print percent downloaded
}

sub _download_file_lwp {
    my ($url_req, $device) = @_;

    unlink $device or die "$! $device" if -e $device;

    $DOWNLOAD_FH = undef;
    $DOWNLOAD_TOTAL = 0;
    sysopen($DOWNLOAD_FH, $device, O_WRONLY|O_EXCL|O_CREAT) ||
		      die "Can't open $device $!";

    my $ua = LWP::UserAgent->new(keep_alive => 1);


    my $url = URI->new(decode(locale => $url_req)) or die "Error decoding $url_req";
    warn $url;

    my $res = $ua->request(HTTP::Request->new(GET => $url)
        ,sub {
            my ($data, $response) = @_;

            unless (fileno $DOWNLOAD_FH) {
                open $DOWNLOAD_FH,">",$device || die "Can't open $device $!\n";
            }
            binmode($DOWNLOAD_FH);
            print $DOWNLOAD_FH $data or die "Can't write to $device: $!\n";
            $DOWNLOAD_TOTAL += length($data);
            my $size = $response->header('Content-Length');
            warn floor(($DOWNLOAD_TOTAL/$size)*100),"% downloaded\n"; # print percent downloaded
        }
    );
    close $DOWNLOAD_FH or die "$! $device";

    close $DOWNLOAD_FH if fileno($DOWNLOAD_FH);
    $DOWNLOAD_FH = undef;

    warn $res->status_line;
}

sub _download_file_external {
    my ($url,$device) = @_;
    my @cmd = ("/usr/bin/wget",,'--quiet',$url,'-O',$device);
    my ($in,$out,$err) = @_;
    warn join(" ",@cmd)."\n";
    run3(\@cmd,\$in,\$out,\$err);
    print $out if $out;
    chmod 0755,$device or die "$! chmod 0755 $device"
        if -e $device;
    die $err if $err;
}

sub _search_iso {
    my $self = shift;
    my $id_iso = shift or croak "Missing id_iso";

    my $sth = $$CONNECTOR->dbh->prepare("SELECT * FROM iso_images WHERE id = ?");
    $sth->execute($id_iso);
    my $row = $sth->fetchrow_hashref;
    die "Missing iso_image id=$id_iso" if !keys %$row;

    $self->_fetch_filename($row);#    if $row->{file_re};
    $self->_fetch_md5($row)         if !$row->{md5} && $row->{md5_url};

    if ( !$row->{device}) {
        if (my $volume = $self->search_volume($row->{filename})) {
            $row->{device} = $volume->get_path;
            my $sth = $$CONNECTOR->dbh->prepare(
                "UPDATE iso_images SET device=? WHERE id=?"
            );
            $sth->execute($volume->get_path, $row->{id});
        }
    }
    return $row;
}

sub _download {
    my $self = shift;
    my $url = shift;

    my $cache = $self->_cache_get($url);
    return $cache if $cache;

    my $ua = new LWP::UserAgent;
    $ua->env_proxy;
    my $req = HTTP::Request->new( GET => $url);
    my $res = $ua->request($req);

    die $res->status_line if !$res->is_success;

    return $self->_cache_store($url,$res->content);
}

sub _cache_get {
    my $self = shift;
    my $url = shift;

    my $file = _cache_filename($url);

    my @stat = stat($file)  or return;
    return if time-$stat[9] > 3600;
    open my $in ,'<' , $file or return;
    return join("",<$in>);
}

sub _cache_store {
    my $self = shift;
    my $url = shift;
    my $content = shift;

    my $file = _cache_filename($url);
    open my $out ,'>' , $file or die "$! $file";
    print $out $content;
    close $out;
    return $content;

}

sub _cache_filename {
    my $url = shift;

    my $file = $url;
    $file =~ tr{/:}{_-};

    return "/var/tmp/$file";
}

sub _fetch_filename {
    my $self = shift;
    my $row = shift;

    if (!$row->{file_re}) {
        my ($file) = $row->{url} =~ m{.*/(.*)};
        confess "No filename in $row->{url}" if !$file;
        $row->{filename} = $file;
        return;
    }
    confess "No file_re" if !$row->{file_re};

    my $content = $self->_download($row->{url});
    my $file;
    my $lines = '';
    for my $line (split/\n/,$content) {
        next if $line !~ /iso"/;
        $lines .= "$line\n";
        my ($found) = $line =~ qr/"($row->{file_re})"/;
        next if !$found;
        $file=$found if $found;
    }
    die "No ".qr($row->{file_re})." found on $row->{url}"   if !$file;

    $row->{filename} = $file;
    $row->{url} .= $file;
}

sub _fetch_md5 {
    my $self = shift;
    my $row = shift;

    my ($file) = $row->{url} =~ m{.*/(.*)};
    confess "No file for $row->{url}"   if !$file;

    my $content = $self->_download($row->{md5_url});

    for my $line (split/\n/,$content) {
        my ($md5) = $line =~ m{^\s*(.*?)\s+.*?$file};
        next if !$md5;
        $row->{md5} = $md5;
        return;
    }

    die "No MD5 for $file in $row->{md5_url}\n".$content;
}

###################################################################################
#
# XML methods
#

sub _define_xml {
    my $self = shift;
    my ($name, $xml_source) = @_;
    my $doc = $XML->parse_file($xml_source) or die "ERROR: $! $xml_source\n";

        my ($node_name) = $doc->findnodes('/domain/name/text()');
    $node_name->setData($name);

    $self->_xml_modify_mac($doc);
    $self->_xml_modify_uuid($doc);
    $self->_xml_modify_spice_port($doc);
    _xml_modify_video($doc);

    return $doc;

}

sub _xml_modify_video {
    my $doc = shift;

    my ( $video , $video2 ) = $doc->findnodes('/domain/devices/video/model');
    ( $video , $video2 ) = $doc->findnodes('/domain/devices/video')
        if !$video;

    die "I can't find video in "
                .join("\n"
                     ,map { $_->toString() } $doc->findnodes('/domain/devices/video'))

        if !$video;
    $video->setAttribute(type => 'qxl');
    $video->setAttribute( ram => 65536 );
    $video->setAttribute( vram => 65536 );
    $video->setAttribute( vgamem => 16384 );
    $video->setAttribute( heads => 1 );

    warn "WARNING: more than one video card found\n".
        $video->toString().$video2->toString()  if $video2;

}

sub _xml_modify_spice_port {
    my $self = shift;
    my $doc = shift or confess "Missing XML doc";

    my ($graph) = $doc->findnodes('/domain/devices/graphics')
        or die "ERROR: I can't find graphic";
    $graph->setAttribute(type => 'spice');
    $graph->setAttribute(autoport => 'yes');
    $graph->setAttribute(listen=> $self->ip() );

    my ($listen) = $doc->findnodes('/domain/devices/graphics/listen');

    if (!$listen) {
        $listen = $graph->addNewChild(undef,"listen");
    }

    $listen->setAttribute(type => 'address');
    $listen->setAttribute(address => $self->ip());

}

sub _xml_modify_uuid {
    my $self = shift;
    my $doc = shift;
    my ($uuid) = $doc->findnodes('/domain/uuid/text()');

    random:while (1) {
        my $new_uuid = _new_uuid($uuid);
        next if $new_uuid eq $uuid;
        for my $dom ($self->vm->list_all_domains) {
            next random if $dom->get_uuid_string eq $new_uuid;
        }
        $uuid->setData($new_uuid);
        last;
    }
}

sub _xml_modify_cdrom {
    my ($doc, $iso) = @_;

    my @nodes = $doc->findnodes('/domain/devices/disk');
    for my $disk (@nodes) {
        next if $disk->getAttribute('device') ne 'cdrom';
        for my $child ($disk->childNodes) {
            if ($child->nodeName eq 'source') {
                $child->setAttribute(file => $iso);
                return;
            }
        }

    }
    die "I can't find CDROM on ". join("\n",map { $_->toString() } @nodes);
}

sub _xml_modify_memory {
    my $self = shift;
     my $doc = shift;
  my $memory = shift;

    my $found++;
    my ($mem) = $doc->findnodes('/domain/currentMemory/text()');
    $mem->setData($memory);

    ($mem) = $doc->findnodes('/domain/memory/text()');
    $mem->setData($memory);

}

sub _xml_modify_network {
    my $self = shift;
     my $doc = shift;
    my $network = shift;

    my ($type, $source );
    if (ref($network) =~ /^Ravada/) {
        ($type, $source) = ($network->type , $network->source);
    } else {
        $network = decode_json($network);
        ($type, $source) = ($network->{type} , $network->{source});
    }

    confess "Unknown network type " if !defined $type;
    confess "Unknown network xml_source" if !defined $source;

    my @interfaces = $doc->findnodes('/domain/devices/interface');
    if (scalar @interfaces>1) {
        warn "WARNING: ".scalar @interfaces." found, changing the first one";
    }
    my $if = $interfaces[0];
    $if->setAttribute(type => $type);

    my ($node_source) = $if->findnodes('./source');
    $node_source->removeAttribute('network');
    for my $field (keys %$source) {
        $node_source->setAttribute($field => $source->{$field});
    }
}

sub _xml_modify_usb {
    my $self = shift;
     my $doc = shift;

    my ($devices) = $doc->findnodes('/domain/devices');

    $self->_xml_remove_usb($devices);
    $self->_xml_add_usb_xhci($devices);

#    $self->_xml_add_usb_ehci1($devices);
#    $self->_xml_add_usb_uhci1($devices);
#    $self->_xml_add_usb_uhci2($devices);
#    $self->_xml_add_usb_uhci3($devices);

    $self->_xml_add_usb_redirect($devices);

}

sub _xml_add_usb_redirect {
    my $self = shift;
    my $devices = shift;

    my $dev=_search_xml(
          xml => $devices
        ,name => 'redirdev'
        , bus => 'usb'
        ,type => 'spicevmc'
    );
    return if $dev;

    $dev = $devices->addNewChild(undef,'redirdev');
    $dev->setAttribute( bus => 'usb');
    $dev->setAttribute(type => 'spicevmc');

}

sub _search_xml {
    my %arg = @_;

    my $name = $arg{name};
    delete $arg{name};
    my $xml = $arg{xml};
    delete $arg{xml};

    confess "Undefined xml => \$xml"
        if !$xml;

    for my $item ( $xml->findnodes($name) ) {
        my $missing = 0;
        for my $attr( sort keys %arg ) {
           $missing++

                if !$item->getAttribute($attr)
                    || $item->getAttribute($attr) ne $arg{$attr}
        }
        return $item if !$missing;
    }
    return;
}

sub _xml_remove_usb {
    my $self = shift;
    my $doc = shift;

    my ($devices) = $doc->findnodes("/domain/devices");
    for my $usb ($devices->findnodes("controller")) {
        next if $usb->getAttribute('type') ne 'usb';
        $devices->removeChild($usb);
    }
}

sub _xml_add_usb_xhci {
    my $self = shift;
    my $devices = shift;

    my $model = 'nec-xhci';
    my $ctrl = _search_xml(
                           xml => $devices
                         ,name => 'controller'
                         ,type => 'usb'
                         ,model => $model
        );
    return if $ctrl;
    my $controller = $devices->addNewChild(undef,"controller");
    $controller->setAttribute(type => 'usb');
    $controller->setAttribute(index => '0');
    $controller->setAttribute(model => $model);

    my $address = $controller->addNewChild(undef,'address');
    $address->setAttribute(type => 'pci');
    $address->setAttribute(domain => '0x0000');
    $address->setAttribute(bus => '0x00');
    $address->setAttribute(slot => '0x07');
    $address->setAttribute(function => '0x0');
}

sub _xml_add_usb_ehci1 {

    my $self = shift;
    my $devices = shift;

    my $model = 'ich9-ehci1';
    my $ctrl_found = _search_xml(
                           xml => $devices
                         ,name => 'controller'
                         ,type => 'usb'
                         ,model => $model
        );
    if ($ctrl_found) {
#        warn "$model found \n".$ctrl->toString."\n";
        return;
    }
    for my $ctrl ($devices->findnodes('controller')) {
        next if $ctrl->getAttribute('type') ne 'usb';
        next if $ctrl->getAttribute('model')
                && $ctrl->getAttribute('model') eq $model;

        $ctrl->setAttribute(model => $model);

        for my $child ($ctrl->childNodes) {
            if ($child->nodeName eq 'address') {
                $child->setAttribute(slot => '0x08');
                $child->setAttribute(function => '0x7');
            }
        }
    }


}

sub _xml_add_usb_uhci1 {
    my $self = shift;
    my $devices = shift;

    return if _search_xml(
                           xml => $devices
                         ,name => 'controller'
                         ,type => 'usb'
                         ,model => 'ich9-uhci1'
    );
    # USB uhci1
    my $controller = $devices->addNewChild(undef,"controller");
    $controller->setAttribute(type => 'usb');
    $controller->setAttribute(index => '0');
    $controller->setAttribute(model => 'ich9-uhci1');

    my $master = $controller->addNewChild(undef,'master');
    $master->setAttribute(startport => 0);

    my $address = $controller->addNewChild(undef,'address');
    $address->setAttribute(type => 'pci');
    $address->setAttribute(domain => '0x0000');
    $address->setAttribute(bus => '0x00');
    $address->setAttribute(slot => '0x08');
    $address->setAttribute(function => '0x0');
    $address->setAttribute(multifunction => 'on');
}

sub _xml_add_usb_uhci2 {
    my $self = shift;
    my $devices = shift;

    return if _search_xml(
                           xml => $devices
                         ,name => 'controller'
                         ,type => 'usb'
                         ,model => 'ich9-uhci2'
    );
    # USB uhci2
    my $controller = $devices->addNewChild(undef,"controller");
    $controller->setAttribute(type => 'usb');
    $controller->setAttribute(index => '0');
    $controller->setAttribute(model => 'ich9-uhci2');

    my $master = $controller->addNewChild(undef,'master');
    $master->setAttribute(startport => 2);

    my $address = $controller->addNewChild(undef,'address');
    $address->setAttribute(type => 'pci');
    $address->setAttribute(domain => '0x0000');
    $address->setAttribute(bus => '0x00');
    $address->setAttribute(slot => '0x08');
    $address->setAttribute(function => '0x1');
}

sub _xml_add_usb_uhci3 {
    my $self = shift;
    my $devices = shift;


    return if _search_xml(
                           xml => $devices
                         ,name => 'controller'
                         ,type => 'usb'
                         ,model => 'ich9-uhci3'
    );
    # USB uhci2
    my $controller = $devices->addNewChild(undef,"controller");
    $controller->setAttribute(type => 'usb');
    $controller->setAttribute(index => '0');
    $controller->setAttribute(model => 'ich9-uhci3');

    my $master = $controller->addNewChild(undef,'master');
    $master->setAttribute(startport => 4);

    my $address = $controller->addNewChild(undef,'address');
    $address->setAttribute(type => 'pci');
    $address->setAttribute(domain => '0x0000');
    $address->setAttribute(bus => '0x00');
    $address->setAttribute(slot => '0x08');
    $address->setAttribute(function => '0x2');

}



sub _xml_remove_cdrom {
    my $doc = shift;

    my ($node_devices )= $doc->findnodes('/domain/devices');
    my $devices = $doc->findnodes('/domain/devices');
    for my $context ($devices->get_nodelist) {
        for my $disk ($context->findnodes('./disk')) {
#            warn $node->toString();
            if ( $disk->nodeName eq 'disk'
                && $disk->getAttribute('device') eq 'cdrom') {

                my ($source) = $disk->findnodes('./source');
                if ($source) {
#                    warn "\n\t->removing ".$source->nodeName." ".$source->getAttribute('file')
#                        ."\n";
                    $disk->removeChild($source);
                }
            }
        }
    }
}

sub _xml_modify_disk {
  my $doc = shift;
  my $device = shift          or confess "Missing device";
  my $swap = shift;

  #  <source file="/var/export/vmimgs/ubuntu-mate.img" dev="/var/export/vmimgs/clone01.qcow2"/>

  my $cont = 0;
  my $cont_swap = 0;
  for my $disk ($doc->findnodes('/domain/devices/disk')) {
    next if $disk->getAttribute('device') ne 'disk';

    for my $child ($disk->childNodes) {
        if ($child->nodeName eq 'driver') {
            $child->setAttribute(type => 'qcow2');
        } elsif ($child->nodeName eq 'source') {
            my $new_device
                    = $device->[$cont++] or confess "Missing device $cont "
                    .Dumper($device);
            $child->setAttribute(file => $new_device);
        }
    }
  }
}

sub _unique_mac {
    my $self = shift;

    my $mac = shift;

    $mac = lc($mac);

    for my $dom ($self->vm->list_all_domains) {
        my $doc = $XML->load_xml(string => $dom->get_xml_description()) or die "ERROR: $!\n";

        for my $nic ( $doc->findnodes('/domain/devices/interface/mac')) {
            my $nic_mac = $nic->getAttribute('address');
            return 0 if $mac eq lc($nic_mac);
        }
    }
    return 1;
}

sub _new_uuid {
    my $uuid = shift;

    my ($principi, $f1,$f2) = $uuid =~ /(.*)(.)(.)/;

    return $principi.int(rand(10)).int(rand(10));

}

sub _xml_modify_mac {
    my $self = shift;
    my $doc = shift or confess "Missing XML doc";

    my ($if_mac) = $doc->findnodes('/domain/devices/interface/mac')
        or exit;
    my $mac = $if_mac->getAttribute('address');

    my @macparts = split/:/,$mac;

    my $new_mac;

    my $n_part = scalar(@macparts) -2;

    for (;;) {
        for my $last ( 0 .. 254 ) {
            $last = sprintf("%X", $last);
            $last = "0$last" if length($last)<2;
            $macparts[-1] = $last;
            $new_mac = join(":",@macparts);
            if ( $self->_unique_mac($new_mac) ) {
                $if_mac->setAttribute(address => $new_mac);
                return;
            }
            $new_mac = undef;
        }
        my $new_part = hex($macparts[$n_part])+1;
        if ($new_part > 255) {
            $n_part--;
            $new_part = 0;
            die "I can't find a new unique mac" if !$n_part<0;
        }
        $macparts[$n_part] = sprintf("%X", $new_part);
    }
    die "I can't find a new unique mac" if !$new_mac;
}

=head2 list_networks

Returns a list of networks known to this VM. Each element is a Ravada::NetInterface object

=cut

sub list_networks {
    my $self = shift;

    $self->connect() if !$self->vm;
    my @nets = $self->vm->list_all_networks();
    my @ret_nets;

    for my $net (@nets) {
        push @ret_nets ,( Ravada::NetInterface::KVM->new( name => $net->get_name ) );
    }

    for my $if (IO::Interface::Simple->interfaces) {
        next if $if->is_loopback();
        next if !$if->address();
        next if $if =~ /virbr/i;

        # that should catch bridges
        next if $if->hwaddr =~ /^[00:]+00$/;

        push @ret_nets, ( Ravada::NetInterface::MacVTap->new(interface => $if));
    }

    $self->vm(undef);
    return @ret_nets;
}

=head2 import_domain

Imports a KVM domain in Ravada

    my $domain = $vm->import_domain($name, $user);

=cut

sub import_domain {
    my $self = shift;
    my ($name, $user) = @_;

    my $domain_kvm = $self->vm->get_domain_by_name($name);
    confess "ERROR: unknown domain $name in KVM" if !$domain_kvm;

    my $domain = Ravada::Domain::KVM->new(
                      _vm => $self
                  ,domain => $domain_kvm
                , storage => $self->storage_pool
    );

    $domain->_insert_db(name => $name, id_owner => $user->id);

    return $domain;
}

1;
