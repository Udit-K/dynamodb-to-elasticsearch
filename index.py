from __future__ import print_function

import os
import json
import re
import boto3
from settings import AppSettings
from sentry_sdk import init, capture_exception
from sentry_sdk.integrations.aws_lambda import AwsLambdaIntegration
from elasticsearch import Elasticsearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth

reserved_fields = [ "uid", "_id", "_type", "_source", "_all", "_parent", "_fieldnames", "_routing", "_index", "_size", "_timestamp", "_ttl"]


ELASTIC_SEARCH_ENDPOINT = os.environ.get("ELASTIC_SEARCH_ENDPOINT")
ES_DOC_TYPE = os.environ.get("ES_INDEX_DOC_TYPE", "doc")

# This is a string that will have `.format()` called against it
# with the dict containing the keys mapping to from Dynamo table's keys
# For example, if you have keys "organization_id" and "group_id", you can
# format your ID as 'organization_id|group_id' with:
#   ES_INDEX_DOC_TYPE = "{organization_id}|{group_id}"
# Using key names that are not present in the dict will raise a KeyError
ES_DOCUMENT_ID_TEMPLATE = os.environ.get("ES_DOCUMENT_ID_TEMPLATE", "")

# Process DynamoDB Stream records and insert the object in ElasticSearch
# Use the Table name as index and doc_type name
# Force index refresh upon all actions for close to realtime reindexing
# Use IAM Role for authentication
# Properly unmarshal DynamoDB JSON types. Binary NOT tested.
settings = AppSettings()
init(dsn=settings.SENTRY_DSN, debug=True, integrations=[AwsLambdaIntegration()])


def lambda_handler(event, context):
    try:
        assert settings.SENTRY_DSN == "not_correct"
    except Exception as e:
        print(settings.SENTRY_DSN)
        capture_exception(e)
        raise
    session = boto3.session.Session()
    credentials = session.get_credentials()

    # Get proper credentials for ES auth
    awsauth = AWS4Auth(credentials.access_key,
                       credentials.secret_key,
                       session.region_name, 'es',
                       session_token=credentials.token)

    # Connect to ES
    es = Elasticsearch(
        [ELASTIC_SEARCH_ENDPOINT],
        http_auth=awsauth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection
    )

    print("Cluster info:")
    print(es.info())

    # Loop over the DynamoDB Stream records
    for record in event['Records']:
        try:
            if not ES_DOCUMENT_ID_TEMPLATE:
                raise Exception("No Elasticsearch document ID template specified")

            if record['eventName'] == "INSERT":
                insert_document(es, record)
            elif record['eventName'] == "REMOVE":
                remove_document(es, record)
            elif record['eventName'] == "MODIFY":
                modify_document(es, record)
                
        except Exception as e:
            print("Failed to process:")
            print(json.dumps(record))
            print("Error:")
            print(e)
            capture_exception(e)
            continue

# Process MODIFY events
def modify_document(es, record):
    table = getTable(record)
    print("Dynamo Table: " + table)

    docId = generateId(record)
    print("KEY")
    print(docId)

    # Unmarshal the DynamoDB JSON to a normal JSON
    doc = json.dumps(unmarshalJson(record['dynamodb']['NewImage']))

    print("Updated document:")
    print(doc)

    # We reindex the whole document as ES accepts partial docs
    es.index(index=table,
             body=doc,
             id=docId,
             doc_type=ES_DOC_TYPE,
             refresh=True)
            
    print("Success - Updated index ID: " + docId)
        
# Process REMOVE events
def remove_document(es, record):
    table = getTable(record)
    print("Dynamo Table: " + table)
    
    docId = generateId(record)
    print("Deleting document ID: " + docId)
    
    es.delete(index=table,
              id=docId,
              doc_type=ES_DOC_TYPE,
              refresh=True)
    
    print("Successly removed")
    
# Process INSERT events
def insert_document(es, record):
    table = getTable(record)
    print("Dynamo Table: " + table)
    
    # Create index if missing
    if es.indices.exists(table) == False:
        print("Create missing index: " + table)
        
        es.indices.create(table,
                          body='{"settings": { "index.mapping.coerce": true } }')
        
        print("Index created: " + table)

    # Unmarshal the DynamoDB JSON to a normal JSON
    doc = json.dumps(unmarshalJson(record['dynamodb']['NewImage']))
    
    print("New document to Index:")
    print(doc)

    newId = generateId(record)
    es.index(index=table,
             body=doc,
             id=newId,
             doc_type=ES_DOC_TYPE,
             refresh=True)
            
    print("Success - New Index ID: " + newId)

# Return the dynamoDB table that received the event. Lower case it
def getTable(record):
    p = re.compile('arn:aws:dynamodb:.*?:.*?:table/([0-9a-zA-Z_-]+)/.+')
    m = p.match(record['eventSourceARN'])
    if m is None:
        raise Exception("Table not found in SourceARN")
    return m.group(1).lower()
    
# Generate the ID for ES. Used for deleting or updating item later
def generateId(record):
    keys = unmarshalJson(record['dynamodb']['Keys'])
    return ES_DOCUMENT_ID_TEMPLATE.format(**keys)

    # # Concat HASH and RANGE key with | in between
    # newId = ""
    # i = 0
    # for key, value in keys.items():
    #     if (i > 0):
    #         newId += "|"
    #     newId += str(value)
    #     i += 1
    #
    # return newId

# Unmarshal a JSON that is DynamoDB formatted
def unmarshalJson(node):
    data = {}
    data["M"] = node
    return unmarshalValue(data, True)

# ForceNum will force float or Integer to 
def unmarshalValue(node, forceNum=False):
    for key, value in node.items():
        if (key == "NULL"):
            return None
        if (key == "S" or key == "BOOL"):
            return value
        if (key == "N"):
            if (forceNum):
                return int_or_float(value)
            return value
        if (key == "M"):
            data = {}
            for key1, value1 in value.items():
                if key1 in reserved_fields:
                    key1 = key1.replace("_", "__", 1)
                data[key1] = unmarshalValue(value1, True)
            return data
        if (key == "BS" or key == "L"):
            data = []
            for item in value:
                data.append(unmarshalValue(item))
            return data
        if (key == "SS"):
            data = []
            for item in value:
                data.append(item)
            return data
        if (key == "NS"):
            data = []
            for item in value:
                if (forceNum):
                    data.append(int_or_float(item))
                else:
                    data.append(item)
            return data

# Detect number type and return the correct one
def int_or_float(s):
    try:
        return int(s)
    except ValueError:
        return float(s)
