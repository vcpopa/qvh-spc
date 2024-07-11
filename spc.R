# Ensure database connection is established and data is retrieved correctly
library(DBI)
library(odbc)
library(NHSRplotthedots)
library(tidyverse)
library(AzureKeyVault)
library(AzureAuth)

# Retrieve client ID, client secret, and tenant ID from environment variables
client_id <- Sys.getenv("AZURE_CLIENT_ID")
client_secret <- Sys.getenv("AZURE_CLIENT_SECRET")
tenant_id <- Sys.getenv("AZURE_TENANT_ID")

# Retrieve database connection details from Key Vault
token <- get_azure_token(
  resource = "https://vault.azure.net",
  tenant = tenant_id,
  app = client_id,
  password = client_secret,
  auth_type = "client_credentials"
)

# Initialize the Key Vault client
kv_client <- key_vault(url = "https://qvh-keyvault.vault.azure.net", token = token)
connection_string <- toString(kv_client$secrets$get("public-dataflow-connectionstring")$value)

# Connect to the database
con <- dbConnect(odbc::odbc(), .connection_string = connection_string)

# SQL query to retrieve data
sql <- "SELECT * FROM scd.vw_SPCSourceData"
df <- dbGetQuery(con, sql) %>%
  mutate(Period = as.Date(Period, format = "%Y-%m-%d"))

# Function to determine variation icon file
variation_icon_file <- function(point_type, improvement_direction) {
  icon <- case_when(
    point_type == "common_cause" ~ "common_cause",
    point_type == "special_cause_neutral_high" ~ "neutral_high",
    point_type == "special_cause_neutral_low" ~ "neutral_low",
    point_type == "special_cause_concern" ~ paste0("concern_", ifelse(improvement_direction == "increase", "low", "high")),
    point_type == "special_cause_improvement" ~ paste0("improvement_", ifelse(improvement_direction == "increase", "high", "low"))
  )
  return(icon)
}

# Get unique measure IDs and dimensions
unique_measure_ids <- unique(df$Measure_ID)
unique_dims <- unique(df$dim1)

# Initialize an empty list to store results
spc_list <- list()

# Loop through each unique Measure_id and dimension
for (measure_id in unique_measure_ids) {
  for (dim_ in unique_dims) {
    # Subset dataframe for the current Measure_id and dimension
    subset_df <- df[df$Measure_ID == measure_id & df$dim1 == dim_, ]
    
    # Check if subset_df is not empty
    if (nrow(subset_df) > 0) {
      target <- unique(subset_df$Target_Value)[1]
      improvement <- unique(subset_df$improvement)[1]

      # Apply ptd_spc function
      spc_result <- subset_df %>% ptd_spc(
        value_field = value,
        date_field = Period,
        improvement_direction = improvement,
        target = target,
        rebase = as.Date("2022-04-01")
      )
      
      # Get latest point type
      latest_point_type <- spc_result %>%
        filter(x == max(x)) %>%
        pull(point_type) %>%
        .[1]
      
      # Calculate assurance_type
      if (is.na(target)) {
        assurance_type <- NULL
      } else {
        assurance <- spc_result %>% summary()
        assurance_type <- assurance %>%
          filter(!is.na(assurance_type)) %>%
          pull(assurance_type) %>%
          .[1]
      }
      
      # Assign assurance_type and variation_type to spc_result
      spc_result <- spc_result %>%
        as.data.frame() %>%
        mutate(Measure_ID = measure_id, assurance_type = assurance_type, dim1 = dim_) %>%
        mutate(variation_type = variation_icon_file(latest_point_type, improvement))
      
      # Store the result in the list
      spc_list[[length(spc_list) + 1]] <- spc_result
    }
  }
}

# Combine all results into a single dataframe
spc <- bind_rows(spc_list) %>%
  mutate(RunDate = as.POSIXct(Sys.time())) %>%
  mutate_all(as.character)

# Write data to the database
odbc::dbWriteTable(con, Id(schema = "scd", table = "SPCMeasures"), spc, append = FALSE, overwrite = TRUE)

# Close database connection
dbDisconnect(con)
