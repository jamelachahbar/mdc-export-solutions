# ============================================================================
# Variables - Streaming SQL Pipeline: CE → Event Hub → Stream Analytics → Azure SQL
# ============================================================================

# ---------- General ----------

variable "subscription_id" {
  description = "Azure subscription ID where resources will be deployed."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group for all pipeline resources."
  type        = string
  default     = "rg-defender-sql-pipeline"
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "uksouth"
}

# ---------- Event Hub ----------

variable "eventhub_namespace_name" {
  description = "Event Hub Namespace name. Must be globally unique."
  type        = string
  default     = "defender-sql-eventhub"
}

variable "eventhub_sku" {
  description = "Event Hub Namespace SKU (Basic or Standard). Basic is sufficient for CE."
  type        = string
  default     = "Basic"
}

variable "eventhub_assessments_name" {
  description = "Event Hub name for Assessments events."
  type        = string
  default     = "defender-findings"
}

variable "eventhub_subassessments_name" {
  description = "Event Hub name for SubAssessments events."
  type        = string
  default     = "defender-subfindings"
}

variable "eventhub_partition_count" {
  description = "Number of partitions per Event Hub. 2 is sufficient for most CE workloads."
  type        = number
  default     = 2
}

variable "eventhub_message_retention" {
  description = "Message retention in days. 1 day is sufficient as ASA processes in near real-time."
  type        = number
  default     = 1
}

# ---------- Azure SQL ----------

variable "sql_server_name" {
  description = "Azure SQL logical server name. Must be globally unique."
  type        = string
  default     = "defender-sql-server"
}

variable "sql_entra_admin_login" {
  description = "Display name for the Entra ID administrator on the SQL server."
  type        = string
  default     = "sqladmin"
}

variable "sql_entra_admin_object_id" {
  description = "Object ID of the Entra ID admin (user or group). If empty, uses the current Terraform executor."
  type        = string
  default     = ""
}

variable "sql_findings_db_name" {
  description = "Database name for Defender findings (raw + typed tables, stored procedures)."
  type        = string
  default     = "DefenderVulnerability"
}

variable "sql_job_db_name" {
  description = "Database name for Elastic Job Agent metadata."
  type        = string
  default     = "DefenderJobMetadata"
}

variable "sql_db_sku" {
  description = "SKU for both SQL databases. GP_S_Gen5_2 = serverless General Purpose, 2 vCores."
  type        = string
  default     = "GP_S_Gen5_2"
}

variable "sql_min_capacity" {
  description = "Minimum vCore capacity for serverless databases (0.5 allows auto-pause)."
  type        = number
  default     = 0.5
}

variable "sql_auto_pause_delay" {
  description = "Auto-pause delay in minutes for serverless databases. -1 disables auto-pause."
  type        = number
  default     = 60
}

variable "sql_max_size_gb" {
  description = "Maximum database size in GB."
  type        = number
  default     = 32
}

# ---------- Stream Analytics ----------

variable "asa_assessments_job_name" {
  description = "Stream Analytics job name for Assessments pipeline."
  type        = string
  default     = "asa-defender-assessments"
}

variable "asa_subassessments_job_name" {
  description = "Stream Analytics job name for SubAssessments pipeline."
  type        = string
  default     = "asa-defender-subassessments"
}

variable "asa_streaming_units" {
  description = "Streaming units per ASA job. 1 is sufficient for CE workloads."
  type        = number
  default     = 1
}

# ---------- Elastic Job Agent ----------

variable "elastic_job_agent_name" {
  description = "Name of the Elastic Job Agent."
  type        = string
  default     = "defender-elastic-agent"
}

variable "elastic_job_umi_name" {
  description = "Name of the User-Assigned Managed Identity for the Elastic Job Agent."
  type        = string
  default     = "mi-elastic-job-agent"
}

# ---------- Tags ----------

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default = {
    Project = "Defender-for-Cloud-SQL-Pipeline"
    ManagedBy = "Terraform"
  }
}
