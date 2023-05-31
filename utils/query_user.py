import query

#https://www.tutorialspoint.com/postgresql/postgresql_using_joins.htm
#SELECT table1.column1, table2.column2...
#FROM table1
#INNER JOIN table2
#ON table1.common_filed = table2.common_field;

#select t1.name, t2.image_id, t3.path
#from table1 t1 
#inner join table2 t2 on t1.person_id = t2.person_id
#inner join table3 t3 on t2.image_id=t3.image_id

#user = "owen.kaluza@monash.edu"
user = "tim.brown@anu.edu.au"

#output = query.do_query(f"select uuid,project_id,name,status,options,pending_action from app_task where id=\'{task}\'") #.split('\n')
output = query.do_query(f"""select p.name,t.id,t.name,t.status from app_task t
                            inner join app_project p on t.project_id = p.id
                            inner join auth_user u on p.owner_id = u.id
                            where u.email = '{user}';""")
print(output)

'''
#https://stackoverflow.com/questions/7869592/how-to-do-an-update-join-in-postgresql
UPDATE table_1 t1
SET foo = 'new_value'
FROM table_2 t2
    JOIN table_3 t3 ON t3.id = t2.t3_id
WHERE
    t2.id = t1.t2_id
    AND t3.bar = True;
'''




