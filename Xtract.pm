# 1. Ensure all file names are quoted
# 2. Try keep bare minimum processing so that user programs will not get loaded with stuff they dont need!
# 3. Comment-out performance tester, it is only usefull during development/testing.

package PDF::Xtract;
use strict;
use vars qw($VERSION);
use File::Temp;
# use Time::HiRes qw(gettimeofday);

$VERSION = '0.02';

my ( $balance, $trailerObject, $RootObject, $EncryptedObject, $InfoObject, $TempExtractFile, $LastExtractFile );
my ( %vars, %objval, %parent, %Referals, %IncludeObjects, %kids, %page, %BabyCountOfObject, %BabiesOfObject );

my $CRLF = '[ \t\r\n\f\0]'."*(?:\015|\012|(?:\015\012))";

# ----------------------------- The Public Methods --------------------------------

# We can put the following 2 lines around a block to see the time taken to execute that.
# my $start=&lt;
# print STDERR "Timer says : ThisBloc: ",&lt-$start,"\n";

sub new {
	my $this = shift;
	my $class = ref($this) || $this;
	my $self = {};
	bless $self, $class;
	# Naming the temperory file for the object as xtract.tmp.CurrentHighResolutionTime.PPID
	(undef,$TempExtractFile)=File::Temp->tempfile("xtract.tmp.XXXX");
	# my @tmp=gettimeofday(); my $tmp=($tmp[0]+$tmp[1]/1000000); $TempExtractFile="xtract.tmp.$tmp.$$";
	$vars{PDFErrorLevel}=3;
	$self->setEnv(@_);
	return $self;
}

#sub cleanup {
#	# Delete temperory files only, user program probably should use this to clean-up the
#	# mess this module might leave behind!
#	close;
#	unlink "$TempExtractFile" if ( -f "$TempExtractFile" );
#}

sub getPDFExtract{				
	local undef $/;
	&setEnv(@_);
	unless ( -f "$LastExtractFile" ) {&error(3,"No extract available at this time"); return 0}
	open ( tmp,"$LastExtractFile" ) or return undef; binmode tmp;
	return <tmp>;
}

sub savePDFExtract{
	# Work expected by this is already done! (if possible); so just move the $TempExtractFile to $vars{PDFSaveAs}
	&setEnv(@_);

	if ( $vars{PDFSaveAs} eq $vars{PDFDoc} ) {
		&error(3,"Attempt to clobber input file @ savePDFExtract!!");
		return 0;
	}

	print STDERR "Info: Please read docs! Xtract autosaves pages to known PDFSaveAS\n" if ( $vars{PDFVerbose} );

	if ( ! $vars{PDFSaveAs} ) {
		&error(3,"No file name specified via PDFSaveAs, so savePDFExtract cant do anything!"); }
	elsif ( "$vars{PDFSaveAs}" eq "$LastExtractFile" ) {
		&error(1,"Redundant operation! Extract already there in $vars{PDFSaveAs}"); return 1;
   	}
	elsif ( -f "$LastExtractFile" ) {
		rename "$LastExtractFile","$vars{PDFSaveAs}";
		$LastExtractFile="$vars{PDFSaveAs}";
		return 1; }
	else {
		&error(3,"No extract available at this time!");}
}

sub getPDFExtractVariables {
	my @var; my $i;
	shift;
	foreach my $key (@_) {
		$var[$i++]=$vars{$key};
	}
	@var;
}

sub getVars { &getPDFExtractVariables(@_); }

sub setPDFExtractVariables {
	my @var;
	&setEnv( @_ );
	shift;
	my %var=@_;
	&getVars( undef, keys %var);
}

sub setVars { &setPDFExtractVariables(@_); }

# ----------------------------- The Private Functions --------------------------------

sub setEnv {
	my (undef,%PDF)=@_;

	if ($PDF{"PDFDebug"} || $vars{PDFDebug} ) {
		$vars{PDFDebug}=$PDF{PDFDebug};
		print STDERR "These variables are to be set\n";
		foreach my $key (keys %PDF) { print STDERR "\t$key=\"$PDF{$key}\"\n"; }
	}

	if ( $PDF{RetainPDFComments} ) { $vars{RetainPDFComments}=$PDF{RetainPDFComments} }
	if ( $PDF{PDFVerbose} ) { $vars{PDFVerbose}=$PDF{PDFVerbose} }; # Put errors to STDERR too
	if ( $PDF{PDFErrorLevel} ) { $vars{PDFErrorLevel}=$PDF{PDFErrorLevel} }; # Errors of higher gravity are
																			 # reported
	if ( $PDF{PDFErrorSize} ) {
		$vars{PDFErrorSize}=$PDF{PDFErrorSize};
		if ( $vars{PDFError} ) { splice @{$vars{PDFError}},0,-$vars{PDFErrorSize} }
	}; # Size of array holding errors

	if ( $PDF{PDFClean} ) { $vars{PDFClean}=$PDF{PDFClean} }; # Generate output only of there is no error

	if ($PDF{PDFDoc} ) {
		# SS: Major changes here!
		# File read mode changed to slurp, understanding the document etc are here.
		# Initialisations:
		$vars{PDFPageCountIn}=$vars{PDFPageCountOut}=$vars{PDFPageCountErr}=undef;
		$vars{PDFPagesFound}=$vars{PDFPagesNotFound}={};

		my $CatalogPages;
		unless ( -f "$PDF{PDFDoc}" ) { &error(3,"PDF document \"$PDF{PDFDoc}\" not found",__FILE__,__LINE__); }
		my $tmp=join(undef,stat("$PDF{PDFDoc}"));
		if ( $vars{PDFDocStat} eq $tmp ) { # SS: Y should you bother if the file is same!
			print STDERR "PDFXtract: You are re-setting object to same PDF Document! I am ignoring it.\n" if ( $vars{PDFVerbose}>0 );
		} else {
			# A new document is being processed.
			$vars{PDFDocStat}=$tmp;
			if ( ! open FILE, "$PDF{PDFDoc}" ) {
				&error(3,"Can't open PDF document  \"$PDF{PDFDoc}\" to read\n",__FILE__,__LINE__);		
			} else {
				local undef $/; binmode FILE; my $pdfFile=<FILE>; close FILE;
				$vars{"PDFDoc"}=$PDF{"PDFDoc"};
				# SS: Understand the document .....
				#----------------------------------
				my @tmp=split(/endobj\s*$CRLF/, $pdfFile); undef $pdfFile;
				%kids=();	# Store kids for all parent objects.
				foreach (@tmp) {
					if ( /(.*?)(\d+)\s+(\d+)\s+obj(.*)/s ) {
						$balance.=$1;
						my $obj=$2; my $inst=$3; $objval{$obj}="$2 0 obj$4endobj\n";
						if ( $objval{$obj}=~/\/Kids\s+\[\s*(.*?)\s+\]/s ) {
							push @{$kids{$obj}},split(/\s+\d+\s+R\s*/,$1);
						}
						if ( $objval{$obj}=~/\/Parent\s+(\d+)\s+\d+\s+R/s ) {
							$parent{$obj}=$1;
						}
						# Make a hash of arrays of referals.
						my @refs=($objval{$obj}=~/\/[^(Root|Info|Pages|Parent|Kids|Enrypt)]\S+\s+(\d+)\s+\d+\s+R[^ALPHA]/gs);
						push (@{$Referals{$obj}},@refs);
					} else { $balance.=$_; }
				}
				# getTrailer, Info etc.
				if ( $balance=~/(trailer\s*<<.*?>>\s*)/s ) {
						$trailerObject=$1;
						$trailerObject=~s/\/Size\s+\d+/\/Size __Size__/s;
						$trailerObject=~s/\/Prev.*?$CRLF//s;

						if ( $trailerObject=~/\/Root\s+(\d+)\s+0\s+R/s ) 	{ $RootObject=$1 }
						if ( $trailerObject=~/\/Encrypt\s+(\d+)\s+0\s+R/ ) 	{ $EncryptedObject=$1 }
						if ( $trailerObject=~/\/Info\s+(\d+)\s+0\s+R/ ) 	{ $InfoObject=$1 }
				}	
				if ( $objval{$RootObject}=~/\/Pages\s+(\d+)\s+0\s+R/ ) 	{ $CatalogPages=$1 }

				&getPages($CatalogPages);
			}
		}
	}

	if ( exists $PDF{PDFSaveAs} ) {   # we also want to be able to set PDFSaveAs to nothing ("")	
		# $PDF{PDFSaveAS}=~s/\.pdf$//i; # ******************
		$vars{"PDFSaveAs"}=$PDF{"PDFSaveAs"};
	}

	if ( $PDF{PDFPages} ) {

		$vars{PDFPageCountOut}=$vars{PDFPageCountErr}=undef;
		$vars{PDFPagesFound}=$vars{PDFPagesNotFound}={};

		# SS: Major change. We plan to accept only array as an input (well, a reference to an array!)
		my $tmp=ref($PDF{PDFPages}); $tmp=$tmp?$tmp:"Not even a reference!"; 
		unless ( $tmp eq "ARRAY" ) {
			&error(3,"Value of PDFPages has to be an array reference, now it is $tmp, No output possible.");
			return 1; }
		my @tmp=@{$PDF{PDFPages}};
		unless ( @tmp ) {
				&error(3,"Can't get PDF Pages. No page numbers were set with 'PDFPages' ",__FILE__,__LINE__);
		}
		@{$vars{PDFPages}}=@tmp;
		# $vars{PDFPageCount}=$vars{PDFPagesFound}=$vars{PDFExtract}="";
		$vars{PDFPagesFound}=""; # $vars{PDFExtract}="";
		%IncludeObjects=(); # %IncludeObjects=undef;
		%BabyCountOfObject=();

		&getPDFDoc(@{$vars{PDFPages}});
		&makePDF;
	}

	if ( $PDF{"PDFDebug"} || $vars{PDFDebug} ) {
		print "These variables have been set\n";
		foreach my $key (keys %vars) { print "\t$key=\"$vars{$key}\"\n"; }

		delete($PDF{PDFDebug});
	}

	# A little buggy, but easier to read in other Xtract environment vars.
	# Allows populating any variables with name starting with "My" to the object's space.
	foreach ( keys %PDF ) { $vars{$_}=$PDF{$_} if ( /^My/ ) }; %PDF=();
}

#------------------------------------ support  Routines --------------------------------------------

sub error {
	# Populates an array of maximum size PDFErrorSize
	my %error_level=(0=>"Silly", 1=>"Info", 2=>"Warn", 3=>"Error");

	my ($error_level,$error)=@_;
	return 0 unless ( $error_level >= $vars{PDFErrorLevel} ); # Ignore those errors below set errorlevel
	# my $size=$vars{PDFError}?scalar(@{$vars{PDFError}}):0;
	if ( $vars{PDFError} && ( @{$vars{PDFError}} >= $vars{PDFErrorSize}) ) {
		shift @{$vars{PDFError}};
	}
	my $error_string="$error_level{$error_level}: $error";
	push ( @{$vars{PDFError}},"$error_string"); 
	print STDERR "$error_string\n" if ( $vars{PDFVerbose} );
	return 1;
}

#------------------------------------ PDF Page Routines --------------------------------------------

sub getPages {
	# Populates Page Number -> Page Object map (%page)
	my @tmp=(shift); my $pageno;
	while ( @tmp ) {
		my $obj=int(shift @tmp);
		if ( $kids{$obj} ) { unshift (@tmp,@{$kids{$obj}}); }
		else { $page{++$pageno}=$obj;
		}
	}
	$vars{PDFPageCountIn}=$pageno;
}

sub Includes{
	# Populates the hash %Includes with (object id)->(objectes refered by object id).
	my @getRefs=@_;
	foreach my $obj ( @getRefs ) {
		foreach my $refered (@{$Referals{$obj}}) {
			$IncludeObjects{$refered}++;
			&Includes($refered);
		}
	}
}

sub getPDFDoc {
	# Key function!!
	# For the given set of pages, generate the page tree for output.

	# Initialisations
	my @pickPages=@_;
	%BabiesOfObject=();
	$vars{PDFPagesFound}=$vars{PDFPageCountOut}=$vars{PDFPageCountErr}=0;
	$vars{PDFPagesFound}=$vars{PDFPagesNotFound}=();
	my $tmp; my $err=0;

	foreach my $pageno ( @pickPages ) {
		unless ( $page{$pageno} ) {	# if the page object is not in %page
			$err++;
			&error(2,"Page No. $pageno is not there in the given PDF file");
			$vars{PDFPageCountErr}++; push(@{$vars{PDFPagesNotFound}},$pageno);
			next;
		}
		$tmp=$page{$pageno};
		$vars{PDFPageCountOut}++; push(@{$vars{PDFPagesFound}},$pageno);
		&Includes($tmp); # Will add refered objs. to %IncludeObjects
		while( $parent{$tmp} ) {	# Contruct/Adjust the object tree for this page
			# Array because, it is important to keep the kids order.
			unless ( grep { /^$tmp$/ } @{$BabiesOfObject{$parent{$tmp}}} ) {
				push (@{$BabiesOfObject{$parent{$tmp}}},$tmp);
				$IncludeObjects{$parent{$tmp}}++;
			} 
			$BabyCountOfObject{$parent{$tmp}}++;
			$tmp=$parent{$tmp};
		}
		$IncludeObjects{$page{$pageno}}++;
	}
	return $err;
}

sub makePDF {

	# Check attempts to clobber input file.
	if ( $vars{PDFSaveAs} eq $vars{PDFDoc} ) {
		&error(3,"Attempt to clobber input file - check PDFSaveAs!!");
		return 0;
	}

	# Decide the file to hold the extracted PDF Stream
	$LastExtractFile=$vars{PDFSaveAs}?$vars{PDFSaveAs}:$TempExtractFile;
	open(FILE,">$LastExtractFile") or die; binmode FILE;

	if ( $vars{PDFClean}>0 ) {
		if ( $vars{PDFPageCountErr}>0 ) {
			&error(3,"PDFClean: $vars{PDFPageCountErr} pages to be extracted were not found");
			close FILE; unlink $LastExtractFile; return undef;
		}
	}
	if ( $vars{PDFPageCountOut}<1 ) { # Clean-up and return if we haven't got any page!
		&error(3,"No pages could be extracted!");
		close FILE; unlink $LastExtractFile; return undef;
	}

	$IncludeObjects{$RootObject}++; # print STDERR "Root ($RootObject) Added\n";
	$IncludeObjects{$InfoObject}++; # print STDERR "Info ($InfoObject) Added\n";

	(my $CurrentBalance=$balance)=~s/\%\%EOF.*//s;
	$CurrentBalance=~s/(.*?$CRLF)//s;

	print FILE "$1$2";
	# I dont know why ghostview complains if I dont keep the '-2' below!
	my $startXref=length($1)-2;

	if ( $vars{RetainPDFComments} ) {
		while ( $CurrentBalance=~/\s*(%.*?)($CRLF)/gs ) {
			print FILE "$1$2";
			$startXref+=length($1.$2);
		}
	}
	my $xref="0000000000 65535 f\015";
	$vars{PDFObjCountOut}=undef;

	foreach my $objid ( sort {$a<=>$b} keys %IncludeObjects ) {
		my $addobj=$objval{$objid};my $babiesofobject=undef;
		foreach ( @{$BabiesOfObject{$objid}} ) { $babiesofobject.=" $_ 0 R"; }
		if ( $babiesofobject ) {
			$addobj=~s/\/Kids\s+.*?\]\s*/\/Kids \[$babiesofobject \]\n/s;
			$addobj=~s/\/Count\s+\d+/\/Count $BabyCountOfObject{$objid}/s;
		}
		$xref.=sprintf("\012%0.10d %0.5d n", $startXref,0);
		$startXref+=length($addobj);
		print FILE "$addobj";
		$vars{PDFObjCountOut}++;
	}
	print FILE "xref\n0 $vars{PDFObjCountOut}\n$xref\015\012";

	(my $CurrentTrailer=$trailerObject)=~s/__Size__/$vars{PDFObjCountOut}/s;
	print FILE "$CurrentTrailer\nstartxref\n$startXref\n\%\%EOF\n";
	close FILE;
}

#sub lt{
#	# Stuff used while debugging and performance checks
#	my @timer=gettimeofday();
#	my $timeNow=$timer[0]+$timer[1]/1000000;
#	return $timeNow;
#}
=head1 AUTHOR

Sunil S, sunils_at_hpcl_co_in

Created by modifying PDF::Extract module by Noel Sharrock (http://www.lgmedia.com.au/PDF/Extract.asp)
(Without PDF::Extract this would not be there!)

Many thanx to inspiration by my collegues at Hindustan Petroleum Corporation Limited, Mumbai, India.

=head1 COPYRIGHT

Copyright (c) 2005 by Sunil S. All rights reserved.


=head1 LICENSE

This package is free software; you can redistribute it and/or modify it under the same terms as Perl itself,
i.e., under the terms of the ``Artistic License'' or the ``GNU General Public License''.

The C library at the core of this Perl module can additionally be redistributed and/or modified
under the terms of the ``GNU Library General Public License''.

=head1 DISCLAIMER

This package is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the ``GNU General Public License'' for more details.

PDF::Xtract - Extracting sub PDF documents from a multipage PDF document


=cut

1;

=head1 Notes

Operational sequences within the module is being changed.  New organisation will be as below:

Essentioal variable for doing anything is PDFDoc.
Extraction and making of document will run as and when PDFPages is defined.  It will be generated into
the disk file named as PDFSaveAs if one exist, else will be taken to default extract file named as
$TempExtractFile.

Populating the PDFExtract is now secondary!  If some one ask for that, we will return the content of the
file $TempExtractFile
