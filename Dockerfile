# Use the rocker/verse base image
FROM --platform=linux/amd64 rocker/verse:latest

# Install required system dependencies
RUN apt-get update && apt-get install -y \
    unixodbc-dev \
    libssl-dev \
    libcurl4-openssl-dev

# Install additional R packages
RUN R -e "install.packages(c('DBI', 'odbc', 'NHSRplotthedots','AzureAuth','AzureKeyVault'))"

# Install Microsoft ODBC Driver for SQL Server
RUN apt-get install -y curl apt-transport-https gnupg
RUN curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
RUN curl https://packages.microsoft.com/config/debian/10/prod.list > /etc/apt/sources.list.d/mssql-release.list
RUN apt-get update
RUN apt-get remove -y libodbc2 libodbcinst2 unixodbc-common
RUN ACCEPT_EULA=Y apt-get install -y msodbcsql17

# Copy the R script to the container
COPY spc.R /app/spc.R

# Set the working directory
WORKDIR /app

# Run the R script when the container starts
CMD ["Rscript", "spc.R"]