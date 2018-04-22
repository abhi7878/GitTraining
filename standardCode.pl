#===============================================================================
#
#         FILE:  ServiceNowUtilities.pm
#
#        USAGE:  See documentation at end of file for further details
#
#  DESCRIPTION:
#        NOTES:  ---
#
#       HEADER:  $Header: //eai/TaskActionSuite/ServiceNowUtilities/trunk/lib/perl5/ServiceNowUtilities.pm#7 $
#     REVISION:  $Revision: #7 $
# REQUIREMENTS:  ---
#       AUTHOR:  Michael Sutherland (micsuth), <Michael.Sutherland@morganstanley.com>
#      COMPANY:  Morgan Stanley
#      CREATED:  11/22/16 10:28:47 EST
#
#===============================================================================

package ServiceNowUtilities;

use strict;
use warnings;

use Data::Dumper; $Data::Dumper::Terse = 1; $Data::Dumper::Indent = 1;
use File::Basename;

my $debug;

# Description:
#   Instantiates a new ServiceNowUtilities object
# Input: $opts (hash ref) - required/optional parameters
# {
#   assignment_group (scalar) - ServiceNow assignment group, required
#   debug (scalar) - Enable debug output, optional
#   env (scalar) - One of dev, qa or prod, optional
#   name (scalar) - Unique namespace for program, optional
# }
# Output: $self (object ref) - instantiated object
#
sub new {
	my $class = shift;
	my $opts = shift || {};

    # Verify required parameters
    die "Missing parameter: assignment_group\n" 
        unless $opts->{'assignment_group'};

    # Toggle debugging
    $ServiceNowUtilities::debug = 1 if $opts->{'debug'};

    # Class defaults
    my $self = {
        'debug' => $opts->{'debug'} || undef,
        'env' => $opts->{'env'} || "prod",
        'escalation' => "/ms/dist/TaskActionSuite/PROJ/IPSoftTools/prod/".
            "common/escalation_check/escalation.pl",
        'escalation-type' => "SERVICENOW",
        'incident' => {},
        'incident_defaults' => {
            'assignment_group' => $opts->{'assignment_group'},
            # S1 -> S5 (S4/S5 are non business impacting)
            'impact_severity' => "S5",
            # 1 = New - Open
            'incident_state' => 1,
            # 3 = Medium
            'priority' => 3,
            'short_description' => undef,
            'u_long_description' => undef,
        },
        'name' => basename($0) || "ServiceNowUtilities",
        'servicenow' => 
            "/ms/dist/rba-utils/PROJ/service-now/1.0.0/bin/service-now.pl",
    };

    # Verify supported environment
    my @allowed_env = ('dev','qa','prod');

    if ( ! grep /^$self->{'env'}$/, @allowed_env ) {
        die sprintf "Invalid environment: %s, expected one of: dev, qa, prod\n",
            $self->{'env'};
    }

    bless $self, $class;

    return $self;
}

# Description:
#   (Re)initialize the object class for a new resource/alarm
# Input: $opts (hash ref) - required/optional parameters
# {
#   details (scalar) - Description of incident
#   resource (scalar) - Affected resource
# }
# Output: n/a
#
sub initialize {
    my $self = shift;
    my $opts = shift || {};

    # Set from defaults
    foreach ( keys %{$self->{'incident_defaults'}} ) {
        $self->{'incident'}->{$_} = $self->{'incident_defaults'}->{$_};
    }

    # Set provided parameters as incident details
    foreach ( keys %$opts ) {
        next if lc $_ eq 'env'; # Strip env
        next if lc $_ eq 'debug'; # Strip debug 
        $self->{'incident'}->{lc $_} = $opts->{lc $_};
    }

    # Set the short and long description values
    unless ( $self->{'incident'}->{'short_description'} && 
        $self->{'incident'}->{'u_long_description'} ) {

        ($self->{'incident'}->{'short_description'}) = 
            split("\n", $self->{'incident'}->{'details'});
        $self->{'incident'}->{'u_long_description'} = 
            $self->{'incident'}->{'details'};
        delete $self->{'incident'}->{'details'};
    }

    $self->{'incident_number'} = undef;

    debug($self);
}

# Description:
#   Track resource by creating a ServiceNow ticket if none already exists. If
#   a ServiceNow ticket already exists update the work notes accordingly.
#   Optionally accept a resource payload which will reinitialize the object,
#   ideal for batch processing where not required to instantiate a new object.
# Input: $opts (hash ref) - required resource parameters
# {
#   details (scalar) - Description of incident, required with optional overide
#   resource (scalar) - Affected resource, required
#   short_description - Set short description, optional overides details
#   u_long_description - Set long description, optional overides details
# }
# Output:
#   $status (int)
#      -1: command failure
#       0: no results
#       1: result returned 
#   $res (scalar) - string message / payload
#
sub track_incident {
    my $self = shift;
    my $opts = shift || {};

    die "Missing parameter: resource\n" unless $opts->{'resource'};

    if (( ! $opts->{'details'} ) && 
        ( ! $opts->{'short_description'} || ! $opts->{'u_long_description'} )) {

        die "Missing parameter(s): details or ".
            "short_description and u_long_description\n";
    }

    # Automatically initialize using provided parameters
    $self->initialize($opts) if $opts;

    # Determine if the resource is already tracked
    my ($status, $res) = $self->get_status();

    # No active ticket found / create
    if ( $status == 0 ) {
        return $self->incident_create();
    }
    # Has active ticket / update
    if ( $status == 1 ) {
        return $self->incident_update()
    }
    # Unexpected error
    else {
        return ($status, $res);
    }
}

9845459842

# Description:
#   Create a new ServiceNow ticket for the provided resource details. Pass-
#   through all parameters to the ServiceNow incident creation method
#   call. If ticket creation is successful, track the ticket in the database.
# Input: n/a
# Output:
#   $status (int)
#      -1: command failure
#       0: no results
#       1: result returned 
#   $res (scalar) - string message / payload
#
sub incident_create {
    my $self = shift;

    # Create the argument string from the incident parameters
    my $servicenow_args;
    foreach ( keys %{$self->{'incident'}} ) {
        next if lc $_ eq 'resource'; # Skip the resource
        $servicenow_args .= " $_='". $self->{'incident'}->{$_} ."'";
    }

    # Create the command string
    my $servicenow_cmd = 
        sprintf "%s %s createIncident --%s",
        $self->{'servicenow'},
        $self->{'env'},
        $servicenow_args,
    ;

    debug("Running: $servicenow_cmd");

    if ( open my $sn, "$servicenow_cmd 2>&1 |" ) {

        my $error;

        while (<$sn>) {
            chomp;
            debug($_);
            ($self->{'incident_number'}) = $_ =~ /(INC\d+)/;

            if ( $_ =~ /error/i ) {
                debug("Unexpected error:", $_);
                $error = $_;
            }
        }

        close $sn;

        return (-1, $error) if $error;
        return $self->insert_status() if $self->{'incident_number'};
        return (0, "No ticket");

    }
    else {

        debug("ERROR: Create ServiceNow Ticket failed", $!);
        return (-1, "ERROR: Create ServiceNow Ticket failed");
    }
}

# Description:
#   Update an existing / open ServiceNow ticket, updating the work notes
#   for a given resource.
# Input:
#   $ticket_num (scalar) - optionally provide a ticket number to update.
# Output:
#   $status (int)
#      -1: command failure
#       0: no results
#       1: result returned 
#   $res (scalar) - string message / payload
#
sub incident_update {
    my $self = shift;
    my $ticket_num = shift || $self->{'incident_number'};

    # Create the argument string from the incident parameters
    my $work_notes = 
        $self->{'incident'}->{'work_notes'} || 
        $self->{'incident'}->{'u_long_description'};

    # Create the command string
    my $servicenow_cmd = 
        sprintf "%s %s updateIncident %s -- work_notes='%s'",
        $self->{'servicenow'},
        $self->{'env'},
        $ticket_num,
        $work_notes,
    ;

    debug("Running: $servicenow_cmd");

    if ( open my $sn, "$servicenow_cmd 2>&1 |" ) {

        my $status;
        my $error;

        while (<$sn>) {
            chomp;
            debug($_);
            $status = 1 if $_ =~ /success/i;

            if ( $_ =~ /error/i ) {
                debug("Unexpected error:", $_);
                $error = $_;
            }
        }

        close $sn;

        return (-1, $error) if $error;
        return (1, "Updated ServiceNow Ticket: $ticket_num") if $status;
        return (0, "No Update");

    }
    else {

        debug("ERROR: Update ServiceNow Ticket failed", $!);
        return (-1, "ERROR: Update ServiceNow Ticket failed");
    }
}

# Description:
#   Close a ServiceNow ticket, providing all values necessary to resolve the
#   ticket. These requirements change depending on the ticket queue and are
#   passed directly to the ServiceNow API. See the ServiceNow API documentation
#   for required values.
# Input:
#   $ticket_num (scalar) - optionally provide a ticket number to update.
#   $opts (hash ref) - 
#       hash ref containing key/value pairs necessary to close a ticket.
# Output:
#   $status (int)
#      -1: command failure
#       0: no results
#       1: result returned 
#   $res (scalar) - string message / payload
#
sub incident_close {
    my $self = shift;
    my $ticket_num = shift || $self->{'incident_number'};
    my $opts = shift || {};

    # Create the resolution argument string from the passed data
    my $servicenow_args;
    foreach ( keys %$opts ) {
        $servicenow_args .= " $_=\"". $opts->{$_} ."\"";
    }

    # Create the command string
    my $servicenow_cmd = 
        sprintf "%s %s closeIncident %s --%s",
        $self->{'servicenow'},
        $self->{'env'},
        $ticket_num,
        $servicenow_args,
    ;

    debug("Running: $servicenow_cmd");

    if ( open my $sn, "$servicenow_cmd 2>&1 |" ) {

        my $status;
        my $res;

        while (<$sn>) {
            chomp;
            debug($_);
            $status = 1 if $_ =~ /success/i;
            last if $status;
            $res = $_;
        }

        close $sn;

        return (1, "Successfully close: ") if $status;
        return (0, $res);
    }
    else {

        debug("ERROR: Close ServiceNow Ticket failed", $!);
        return (-1, "ERROR: Close ServiceNow Ticket failed");
    }
}

# Description:
#   Create a new entry in the database in order to track a given resource. 
#   These entries are unique based on the defined 'resource' and the caller
#   'name'
# Input: $ticket_num (scalar) - optionally provide a ticket number to update.
# Output:
#   $status (int)
#      -1: command failure
#       1: result returned 
#   $res (scalar) - string message / payload
#
sub insert_status {
    my $self = shift;
    my $ticket_num = shift || $self->{'incident_number'};

    my $escalation_cmd = sprintf
        "%s -insert -node '%s' -autoname '%s' ".
        "-issueid '%s' -esctype '%s' -env '%s'",
        $self->{'escalation'},
        $self->{'incident'}->{'resource'},
        $self->{'name'},
        $ticket_num,
        $self->{'escalation-type'},
        $self->{'env'},
    ;

    debug("Running: $escalation_cmd");

    if ( open my $status, "$escalation_cmd 2>&1 |" ) {
        while (<$status>) {
            chomp;
            debug($_);
        }
        close $status;
        return (1, "$ticket_num");
    }
    else {
        debug("ERROR: Insert ServiceNow Ticket failed", $!);
        return (-1, "ERROR: Insert ServiceNow Ticket failed");
    }
}

# Description:
#   Query the database for a given 'resource' and 'name' determining if an
#   entry already exists. If an entry exists return the ServiceNow ticket number
#   if it is found to still be open.
# Input: n/a
# Output:
#   $status (int)
#      -1: command failure
#       0: no results
#       1: result returned 
#   $res (scalar) - string message / payload
#
sub get_status {
    my $self = shift;

    my $escalation_cmd = 
        sprintf "%s -check -node '%s' -autoname '%s' -esctype '%s' -env '%s'",
        $self->{'escalation'},
        $self->{'incident'}->{'resource'},
        $self->{'name'},
        $self->{'escalation-type'},
        $self->{'env'},
    ;

    debug("Running: $escalation_cmd");

    if ( open my $status, "$escalation_cmd 2>&1 |" ) {

        my $error;

        while (<$status>) {
            chomp;
            debug($_);
            ($self->{'incident_number'}) = $_ =~ /(INC\d+)/;

            if ( $_ =~ /error/i ) {
                debug("Unexpected error:", $_);
                $error = $_;
            }
        }

        close $status;

        return (-1, $error) if $error;
        return (1, $self->{'incident_number'}) if $self->{'incident_number'};
        return (0, "No ticket");
    }
    else {
        debug("ERROR: Check ticket status failed", $!);
        return (-1, "ERROR: Check ticket status failed");
    }  
}

# Description:
#   Print debug information to stderr.
# Input: 
#   @_ (array) - optional, all other arguments are treated as the debug payload
# Output: undef
#
sub debug {

    # Return if debugging is disabled
    return unless $ServiceNowUtilities::debug;
    return unless scalar @_;

    # Determine the calling function name and line number
    my $meta = {
        'function' => (caller(1))[3] || (split(/\//, $0))[-1],
        'line' => (caller(0))[2] || ''
    };
    $meta->{'function'} =~ s/^main:://;

    # Get a current timestamp
    my ($sec,$min,$hour,$mday,$mon,$year,@others) = localtime(time);
    my $timestamp = sprintf '%s/%s/%s %02u:%02u:%02u', 
        $year+1900, $mon+1, $mday, $hour, $min, $sec;

    # Format debug info
    printf STDERR "[%s] %s(%s) > ",
        $timestamp,
        $meta->{'function'},
        $meta->{'line'},
    ;

    foreach ( @_ ) {

        my $line = $_ || "";

        if ( ref $line ) {
            print STDERR Dumper($line);
        }
        else {
            $line =~ s/\n*$//;
            print STDERR "$line\n";
        }
    }
}

1;

=head1 NAME
    ServiceNowUtilities - Create and track a given resource by creating or
    updating a ServiceNow incident ticket.
=head1 SYNOPSIS
    use ServiceNowUtilities;
    my $snu = ServiceNowUtilities->new({
        'assignment-group' => 'some_ticket_queue',
        ...
    });
    my ($status, $result) = $snu->track_incident({
        'details' => 'description of event',
        'resource' => 'resource name',
        ...
    });
    if ( $status == 1 ) {
        print "Success: $result\n";
    }
    elsif ( $status == 0 ) {
        print "Unable to track: $result\n";
    }
    else {
        print STDERR "Error: $result\n";
    }
=head1 DESCRIPTION
This module can be used by a Perl program to track a resource by creating and
updating a ServiceNow ticket for the event. When an open ticket exists for a 
reoccuring event the tickets work notes are updated accordingly.  This continues
until the event is resolved and the ticket is closed.
$snu->track_incident() does the following:
=over 4
=item 1
Check the database to determine if an entry already exists. When an entry is
found it further checks to see if the tracked ServiceNow ticket number is still
active and not closed.
=item 2
In the event an active entry is not found, the incident_create() method is
called which creates a new ServiceNow ticket and an entry in the database.
=item 3
In the event an active entry is found, the incident_update() method is called
which updates the work notes of the existing ticket.
=item 4
In the event of an error the status and error message are returned.
=back
=head1 CONSTRUCTOR
=over 4
=item new({ 'key' => 'value', ... })
The new constructor instantiates an instance of the ServiceNowUtilities object. 
The following keys are used:
Required:
=over 8
=item assignment_group
Define the ServiceNow assignment_group where tickets are created.
=back
Optional:
=over 8
=item debug
Set to a positive integer to enable debug output.
=item env
Set the environment used by the module to connect to the tracking database as 
well as the ServiceNow API for ticket creation. Defaults to prod. 
Supported values are: dev, qa, prod
=item name
Specify the program namespace which will be used in combination with the
resource in order to identify the corresponding information tracked in 
the database. If not specified, the value returned from $0 is used.
=back
Example:
    my $snu = ServiceNowUtilities->new({
        'assignment_group' => 'SOME_QUEUE',
        # optional:
        # 'debug' => 1,
        # 'env' => 'qa',
        # 'name' => 'my_program123',
    });
=back
=head1 METHODS
=over 4
=item new(({ ... })
Used to instantiate a new object and define the environment as well as the
ticket assignment queue to be used.
=item track_incident({ ... })
Determines what if any tracking already exists for a given event. If an existing
active ticket is found the ticket is reused and updated accordingly. If none
exist a new Incident ticket is created and an entry created in the database
in order to track it going forward.
This method requires the resource specified using the resource key, as well as
a description of the event, provided by keys: details or by specifying the 
ServiceNow API values: short_description and u_long_description.  When only
details is provided, the first line is used as the short description and the
long description contains the entire value.
If any additional parameters are provided as key/value pairs they are passed 
directly to the ServiceNow API when creating or updating a ticket. These values
are not validated by this module. See the ServiceNow API documentation for 
required values.
=over 4
=item *
details
=item *
short_description
=item *
u_long_description
=back
Example:
    my ($status, $result) = $snu->track_incident({
        'resource' => "resource name",
        'details' => "Short description\nFull details of the event.",
    });
    # Or instead of details
    my ($status, $result) = $snu->track_incident({
        'resource' => "resource name",
        'short_description' => "Brief description of the event",
        'u_long_description' => "Multiline\ndescription of the event.",
    });
=over 4
=item * key => value
=back
Any additional parameters are passed directly to the ServiceNow API. In this 
way the program is not limited by hard coded values and can be used to populate 
addition fields in the ticket as necessary. 
See the ServiceNow API documentation for required values.
=back
=head1 OTHER METHODS
ServiceNowUtilities also defines some additional internally used functions.
=over 4
=item initialize({ ... })
Called automatically by the track_incident() method. This method (re)initializes
the object with the details provided. Allowing the object class to be
instantiated once, then reused for multiple events with each call to 
track_incident().
=item incident_create()
Create a new ServiceNow ticket for the provided resource details. Pass-through
all parameters to the ServiceNow incident creation method call. If ticket 
creation is successful, create a corresponding entry in the database.
=item incident_update()
Update an existing / open ServiceNow ticket, updating the work notes for a 
given resource.
=item incident_close($ticket_number, { ... })
Close a ServiceNow ticket, provide all values necessary to close the ticket. 
These requirements change depending on the ticket queue and are passed directly 
to the ServiceNow API as provided. These values are not validated by this 
module. See the ServiceNow API documentation for required values.
=item insert_status()
Create a new entry in the database in order to track a given resource. These 
database entries are unique based on the defined 'resource' and 'name' set when
instantiating the object.
=item get_status()
Query the database for a given 'resource' and 'name'. If an entry already 
exists and the ticket is still active in ServiceNow return the ServiceNow 
ticket number.
=item debug()
Subroutine for printing debug information to STDERR, includes calling function
name and line number. Requires $ServiceNowUtilities::debug to be set to 1 to
produce output.
=back
=head1 NOTES
$snu->{'incident_number'} stores the ServiceNow Incident ticket number 
when available. This can be utilized by the calling program instead of having 
to parse the value from the returned result string.
=head1 AUTHORS
Current Version
=over 4
=item *
Michael Sutherland, E<lt>Michael.Sutherland@morganstanley.comE<gt>
=back
Previous Versions
=over 4
=item *
Abhishek Anand, E<lt>Abhishek.Anand@morganstanley.comE<gt>
=back
=head1 PREREQUISITES
This module requires at least perl version 5.14.
=head1 REPOSITORY
L<http://p4webeai/eai/TaskActionSuite/ServiceNowUtilities/trunk/?ac=83>
=head1 SEE ALSO
=head1 COPYRIGHT
Copyright (C) 2012 Morgan Stanley & Co. Incorporated, All Rights Reserved.
Unpublished copyright. All rights reserved. This material contains
proprietary information that shall be used or copied only within Morgan
Stanley, except with written permission of Morgan Stanley.
Contact GitHub API Training Shop Blog About
© 2017 GitHub, Inc. Terms Privacy Security Status Help