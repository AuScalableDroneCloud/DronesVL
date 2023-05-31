import psycopg2
from psycopg2 import Error

try:
    # Connect to an existing database
    connection = psycopg2.connect(user="postgres",
                                  password="postgres",
                                  host="db",
                                  port="5432",
                                  database="webodm_dev")

    # Create a cursor to perform database operations
    cursor = connection.cursor()
    # Print PostgreSQL details
    print("PostgreSQL server information")
    print(connection.get_dsn_parameters(), "\n")
    # Executing a SQL query
    cursor.execute("SELECT version();")
    # Fetch result
    record = cursor.fetchone()
    print("You are connected to - ", record, "\n")

    # Executing a SQL query
    cursor.execute("SELECT id,username from auth_user order by id;")
    # Fetch result
    records = cursor.fetchall()
    print("Auth users:", records, "\n")
    #for row in records:
    #    print("Id = ", row[0], )
    #    print("UName = ", row[1])

except (Exception, Error) as error:
    print("Error while connecting to PostgreSQL", error)
finally:
    if (connection):
        cursor.close()
        connection.close()
        print("PostgreSQL connection is closed")
