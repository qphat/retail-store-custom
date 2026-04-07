[SERVICE]
    Flush         1
    Log_Level     ${log_level}
    Parsers_File  parsers.conf
    HTTP_Server   On
    HTTP_Listen   0.0.0.0
    HTTP_Port     2020

# Add environment metadata to every log record
[FILTER]
    Name   record_modifier
    Match  *
    Record environment ${env_name}
    Record cluster     retail-store

[OUTPUT]
    Name            es
    Match           *
    Host            ${es_host}
    Port            9200
    Index           logs-$${SERVICE_NAME}
    Type            _doc
    tls             Off
    Retry_Limit     3
    Generate_ID     On
    Replace_Dots    On
    Trace_Error     On
    # Buffer locally if ES is unreachable — up to 5MB before dropping
    storage.total_limit_size 5M
