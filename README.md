<h1 align="left">Terraforming Snowflake</h1>

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Getting started](#getting-started)
  - [Dependencies](#dependencies)
  - [Pre-commit Hooks](#pre-commit-hooks)
  - [Installing Snowsql](#installing-snowsql)
  - [Setting your ENV VARS](#setting-your-env-vars)
- [Creating Infrastructure](#creating-infrastructure)
  - [Remote state and lock table](#remote-state-and-lock-table)
  - [Provisioning Snowflake resources](#provisioning-snowflake-resources)
  - [Creating Snowpipes](#creating-snowpipes)
    - [The Specifics](#the-specifics)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

This repo applies an infrastructure as code approach to deploying Snowflake resources using Terraform. It relies on the [open source provider by the Chan Zuckerberg Initiative](https://github.com/chanzuckerberg/terraform-provider-snowflake) and can create, alter and destroy users, roles and resources in Snowflake.

Making use of Snowflake's default and recommended roles, this project creates the majority of infrastructure with the `SYSADMIN` role, users and roles are administered by the `SECURITYADMIN` role, and account integrations and related resources are owned by the `SYSADMIN` role.

# Getting started
## Dependencies
In order to contribute or run this project, you will need:

- [terraform v0.13.0](https://www.terraform.io/)
- [terraform-provider-snowflake v0.15](https://github.com/chanzuckerberg/terraform-provider-snowflake)
- [snowsql v1.2.9](https://docs.snowflake.com/en/user-guide/snowsql.html)
- [AWS Command Line Interface v2.0.46](https://aws.amazon.com/cli/)
- [pre-commit](https://pre-commit.com/)

## Pre-commit Hooks

This project uses pre-commit hooks as a means to keep code readable and a measure to prevent broken code from being rolled out.

Before committing code for the first time, make sure to initialise the hooks:

    pre-commit install

From now on, pre-commit checks will be run any time you make a commit on the project.

You may also optionally run these checks against all extant files in the project:

    pre-commit run --all-files

**Important note: if your code fails pre-commit checks, your commit will be cancelled. You'll need to fix the issues and commit again.**

## Installing Snowsql
The project uses the Snowsql CLI for resource creation where the Terraform provider lacks the functionality; this includes table creation particularly when deploying Snowpipes. Follow the download instructions [here](https://docs.snowflake.com/en/user-guide/snowsql-install-config.html#installing-snowsql) or if you have homebrew use:

    brew cask install snowflake-snowsql

This will also create a config file in `~/.snowsql/config` used for authentication and setting default values such as role and warehouse.

Edit the file and create a Snowflake profile (connections is the default profile), e.g:

    [connections]
    accountname = YourAccountId
    region = eu-west-1
    username = YourUserName
    password = infinityworkspartner

If you are using multiple Snowflake accounts you can create additional profiles in this file using the same structure:

    [connections.iw]
    accountname = infinityworkspartner
    region = eu-west-1
    username = YourUserName
    password = YourPassword


## Setting your ENV VARS
To deploy Snowflake using Terraform, this project depends on user authentication by environment variables; to simplify this process we load the snowsql config credentials using a python script; the two env vars outputted are `SNOWFLAKE_USER` and `SNOWFLAKE_PASSWORD`.

The python script accepts two optional arguments, `profile` and `application`; these determine the Snowflake profile you wish to use and the env vars to export. If the flags are not called, they will default to using your `connections` profile and output both terraform and SnowSQL env vars. **The CLI arguments are case sensitive**. The accepted values for `application` are `terraform`, `snowsql` or `all`, for example:

     eval $(python3 load_snowflake_credentials.py --profile connections.iw --application terraform)

NOTE: This must be run in an `eval $( )` statement as the python script prints your vars to the terminal and `eval` evaluates the export statement, loading them into your environment. **If you do not use the `eval` statement your creds will be printed in plain text to your terminal and not loaded into your environment variables**.

Remember to execute this `eval` statement for each terminal window you are working in.

# Creating Infrastructure

## Remote state and lock table
To begin we must create a remote state bucket and lock table within an AWS account; this is referenced to keep track of all changes made by Terraform and ensures stateful deployments.

The remote state bucket and lock table's name are comprised of your project name, this can be updated in `./aws/state_resources/s3/environment/dev/environment.tfvars`. After authenticating a local session to your AWS account, navigate to `./aws/state_resources/s3` and execute:

    terraform init
    terraform plan -var-file=environment/dev/environment.tfvars -out=tfplan
    terraform apply tfplan
    rm -r .terraform && rm tfplan

This will create a remote state bucket with the name `<your-project>-remote-state-<env>`. Next for the lock table, again changing the `environment.tfvars` project name:

    cd ../dynamoDB
    terraform init -backend=true -backend-config=environment/dev/backend-config.tfvars
    terraform plan -var-file=environment/dev/environment.tfvars -out=tfplan
    terraform apply tfplan
    rm -r .terraform && rm tfplan

Check with the CLI that `<your-project>-lock-table` now exists.

Now we have our state infrastructure we can begin Terraforming Snowflake and its AWS counterparts.

## Provisioning Snowflake resources
Some resources are dependent on others already existing, for example schemas belong to databases, and stages belong to a schema within a database; thus we must deploy resources in a specific order. They have not been linked through modules and outputs as this causes deployment and destruction conflicts; for example, a non-existing database would be created if a schema linked to it was created first, this would mean the state information for the database is in the schema state file and we cannot independently modify said database - therefore they are referred to using the remote state output and snowflake appears to look for existence of names, not IDs. With this knowledge we must respect a deployment order:

1. RBAC
1. Databases
1. Schemas
1. Integrations
1. Stage
1. Pipes

Each directory containing a resource type has an associated `main.tf` file which declares the provider; this provider includes the Snowflake account name, region and role which is adopted to create, modify and destroy infra. You must ensure you can adopt the appropriate roles required.

To create users and roles, navigate to `./Snowflake/rbac/` and run:

    terraform init -backend=true -backend-config=environment/backend-config.tfvars
    terraform plan -var-file=environment/environment.tfvars -out=tfplan
    terraform apply tfplan
    rm -r .terraform && rm tfplan

This pattern of initialisation, planning and deployment is repeated across each directory to create resources.

Try creating a warehouse.

## Creating Snowpipes
Creating roles, databases and warehouses are easy, creating Snowpipes requires a little finesse. The following summaries the steps, though the specifics which follow must be observed.
- First deploy the data lake bucket in `./aws/s3/`.
- Next we must create a database and schema where an external stage can live.
- If it does not already exist, create the landing table where data will be ingested into.
- Next we require an account integration to connect to an external AWS account.
- Once this has been established we can create the external stage, which is dependent on the account integration and S3 data lake bucket.
- Now Snowflake has set its external ID we can create the IAM role which will allow Snowflake to read from the S3 data lake, this is located in `./aws/iam/`.
- Finally, create the Snowpipe. The pipe's SQS ARN is immediately used to configure the S3 event notifications. As files land in the bucket they will be consumed and data copied to the landing table.


### The Specifics
First name your project, this name will comprise the data lake bucket name and will persist in infra naming throughout. You will find this in `aws/s3/environment/environment.tfvars`.

Next create the data lake from which we will consume `.csv` files; navigate to `./aws/s3/` and run:

    terraform init -backend=true -backend-config=environment/backend-config.tfvars
    terraform plan -var-file=environment/environment.tfvars -out=tfplan
    terraform apply tfplan
    rm -r .terraform && rm tfplan

Following this create the users, roles, databases and schemas by navigating to each respective directory and again running:

    terraform init -backend=true -backend-config=environment/backend-config.tfvars
    terraform plan -var-file=environment/environment.tfvars -out=tfplan
    terraform apply tfplan
    rm -r .terraform && rm tfplan

Snowpipe requires a target table to store data in, the simplest way to create this is in the console as follows:

    USE DATABASE <target-database>;
    USE SCHEMA <target-schema>;
    CREATE TABLE IF NOT EXISTS <table-name> (<DDL STATEMENT>);

To connect your external AWS account you must create a cloud account integration; to do this begin by changing the variables in `snowflake/infra/storage_integrations/environment/environment.tfvars`, this includes your AWS cloud ID and the S3 IAM role name associated with the bucket you wish to connect a pipe to. The IAM name is set here and will persist to the IAM resources when they are deployed in later steps; note that these parameters are referenced by name and not ID, meaning they can be set in Snowflake before their existence in AWS, providing you are certain of the name availability. Set these variables and deploy the integration.

Next create the external stage which depends on this integration.

Finally create the pipe by navigating to `snowflake/infra/pipes/`and run

    terraform init -backend=true -backend-config=environment/backend-config.tfvars
    terraform plan -var-file=environment/environment.tfvars -out=tfplan
    terraform apply tfplan
    rm -r .terraform && rm tfplan

This will also configure the event notifications on the S3 data lake bucket. Your pipe should now be visible and you can check its status with:

    SELECT system$pipe_status('"ANALYTICS"."PUBLIC"."DATA_LAKE_PIPE"');

As you load files into the S3 bucket, these will now be consumed into the snowflake table.

Note: If you modify or recreate the account integration, a new `snowflake_external_id` will be generated; the proceeding steps including stage, IAM and pipe creation will need to be repeated.
