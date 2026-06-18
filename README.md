# ripe-country-blocker

Intended to block network traffic from/to entire countries in dev environments using up-to-date data from the RIPE database.

This script supports local packet filtering via iptables/ipset as well as cloud-managed filtering via Google Cloud Compute Engine firewall rules.

## Usage

./ripe-country-blocker.sh --cc=XX [options]

### Options
**--cc=XX**
The 2-digit ISO-3166 country code to block. Examples include CH, US, IN, BR, RU. This argument is required.

**--i**
Block ingress (incoming) traffic.

**--e**
Block egress (outgoing) traffic.

**--a**
Block all traffic (both ingress and egress). This is the default behavior.

**--v**
Verbose mode. Enables debug output in the console.

**--D**
Delete or flush existing rules for the specified country.

This flushes the ipset. To completely destroy the ipset, the iptables service must be stopped prior to running ipset destroy SETNAME.

When using --gcloud, this deletes the matching firewall rules from your project.

**--gcloud**
Use Google Cloud firewall infrastructure. This option requires the gcloud CLI tool to be configured locally with an IAM identity.

**--o=/tmp**
Specify the output directory where the raw RIPE database files and temporary artifacts are saved. Defaults to /tmp.

**--help, --h**
Display the help menu and exit.

#### Google Cloud (gcloud)

When the --gcloud flag is passed, the script bypasses local filters and deploys VPC-wide firewall rules instead. Please keep the following platform quotas in mind:

Google Cloud enforces a maximum limit of 5000 entries per individual firewall rule (including CIDR blocks).

There is a maximum limit on total project firewall rules depending on the complexity of each rule.
