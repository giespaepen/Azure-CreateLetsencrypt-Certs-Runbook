# Azure Create Let's Encrypt Certificates Runbook
> Azure Runbook to create certificates in a keyvault and to renew them.

## Introduction
When using azure services with e.g. custom domain names you want to use TLS of course.
Buying certificates implies a cost. This runbook enables you to get certificates
from Let's Encrypt to securre your (web)services with custom domain names.

## What you need
- An azure subscription
- A resource group with:
    - A key vault
    - A DNS zone
    - An automation account with a `run as account` enabled

## Setup
- The DNS zone must work of course. It should contain one or more A record. 
- The `run as account` should have `DNS Zone Contributor` rights in the DNS zone.
- The `run as account` should have `certificate management` and `get and list secrets` rights in the key vault

Create a runbook and past the `Runbook.ps1` script in it. Configure the variables and run it. Publish it 
and then configure a schedule to run it every week.

That should be it. 

## Contribute
Feel free to fork copy and edit the script for your personal cases and use. However, if you can improve it, send me a PR. 