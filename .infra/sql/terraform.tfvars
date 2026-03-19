# ============================================================================
# Example variable values - Streaming SQL Pipeline
# ============================================================================
# Copy this file to terraform.tfvars and update values for your environment.

subscription_id     = "34f635ef-9210-4e8f-b9a9-8c3327604b23"
resource_group_name = "rg-defender-sql-pipeline-2"
location            = "westus2"

# ---------- Event Hub ----------
eventhub_namespace_name      = "defender-sql-eventhub-2"
eventhub_sku                 = "Standard"
eventhub_assessments_name    = "defender-findings-2"
eventhub_subassessments_name = "defender-subfindings-2"
eventhub_partition_count     = 2
eventhub_message_retention   = 1

# ---------- Azure SQL ----------
sql_server_name           = "defender-sql-server-2"
sql_entra_admin_login     = "sqladmin"
sql_entra_admin_object_id = ""          # Leave empty to use current Terraform executor
sql_findings_db_name      = "DefenderVulnerability"
sql_job_db_name           = "DefenderJobMetadata"
sql_db_sku                = "GP_S_Gen5_2"   # Serverless General Purpose, 2 vCores
sql_min_capacity          = 0.5             # Allows auto-pause
sql_auto_pause_delay      = 60              # Minutes; -1 disables auto-pause
sql_max_size_gb           = 32

# ---------- Stream Analytics ----------
asa_assessments_job_name    = "asa-defender-assessments-2"
asa_subassessments_job_name = "asa-defender-subassessments-2"
asa_streaming_units         = 1             # 1 SU ≈ $80/mo per job

# ---------- Elastic Job ----------
elastic_job_agent_name = "defender-elastic-agent-2"
elastic_job_umi_name   = "mi-elastic-job-agent-2"

# ---------- Tags ----------
tags = {
  Project   = "Defender-for-Cloud-SQL-Pipeline"
  ManagedBy = "Terraform"
}
