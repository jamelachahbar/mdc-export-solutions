# ============================================================================
# Outputs - Streaming SQL Pipeline: CE → Event Hub → Stream Analytics → Azure SQL
# ============================================================================

# ---------- Event Hub ----------

output "eventhub_namespace_id" {
  description = "Event Hub Namespace resource ID."
  value       = module.eventhub_namespace.resource.id
  sensitive   = true
}

output "eventhub_assessments_id" {
  description = "Event Hub resource ID for Assessments."
  value       = module.eventhub_namespace.resource_eventhubs[var.eventhub_assessments_name].id
}

output "eventhub_subassessments_id" {
  description = "Event Hub resource ID for SubAssessments."
  value       = module.eventhub_namespace.resource_eventhubs[var.eventhub_subassessments_name].id
}

# ---------- Azure SQL ----------

output "sql_server_fqdn" {
  description = "Fully qualified domain name of the SQL server. Use with Initialize-Bootstrap.ps1 -SqlServerFqdn."
  value       = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "sql_server_id" {
  description = "SQL Server resource ID."
  value       = azurerm_mssql_server.this.id
}

output "sql_findings_db_name" {
  description = "Findings database name."
  value       = azurerm_mssql_database.findings.name
}

output "sql_job_db_name" {
  description = "Job metadata database name."
  value       = azurerm_mssql_database.job_metadata.name
}

# ---------- Stream Analytics ----------

output "asa_assessments_job_id" {
  description = "Stream Analytics job ID for Assessments."
  value       = azurerm_stream_analytics_job.assessments.id
}

output "asa_assessments_principal_id" {
  description = "System-assigned MI principal ID for Assessments ASA job. Use with bootstrap SQL for SQL permissions."
  value       = azurerm_stream_analytics_job.assessments.identity[0].principal_id
}

output "asa_subassessments_job_id" {
  description = "Stream Analytics job ID for SubAssessments."
  value       = azurerm_stream_analytics_job.subassessments.id
}

output "asa_subassessments_principal_id" {
  description = "System-assigned MI principal ID for SubAssessments ASA job. Use with bootstrap SQL for SQL permissions."
  value       = azurerm_stream_analytics_job.subassessments.identity[0].principal_id
}

# ---------- Elastic Job ----------

output "elastic_job_agent_id" {
  description = "Elastic Job Agent resource ID."
  value       = azurerm_mssql_job_agent.this.id
}

output "elastic_job_umi_id" {
  description = "User-Assigned Managed Identity resource ID. Assign to Elastic Job Agent post-deployment."
  value       = azurerm_user_assigned_identity.elastic_job.id
}

output "elastic_job_umi_name" {
  description = "User-Assigned Managed Identity name. Use with bootstrap SQL (ElasticJobUmiName parameter)."
  value       = azurerm_user_assigned_identity.elastic_job.name
}

output "elastic_job_umi_client_id" {
  description = "UMI client ID."
  value       = azurerm_user_assigned_identity.elastic_job.client_id
}

# ---------- Pipeline Summary ----------

output "pipeline_summary" {
  description = "End-to-end pipeline configuration summary."
  value = {
    architecture       = "CE → Event Hub → Stream Analytics → Azure SQL"
    resource_group     = azurerm_resource_group.this.name
    location           = var.location
    eventhub_namespace = module.eventhub_namespace.resource.name
    sql_server         = azurerm_mssql_server.this.fully_qualified_domain_name
    findings_database  = azurerm_mssql_database.findings.name
    asa_jobs           = [var.asa_assessments_job_name, var.asa_subassessments_job_name]
    elastic_job_agent  = azurerm_mssql_job_agent.this.name
    post_deployment    = "Run Initialize-Bootstrap.ps1, then configure Elastic Job schedule"
  }
}
