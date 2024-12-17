# RP Connect Pizza Tracker

You just bought a pizza restaurant, nice! You tell people it's because you always wanted to feed the hungry, but really, you just like eating obscene amounts of BBQ chicken pizza when no one's looking.

We won't judge you, but we do want to help you implement an order tracking system so you can keep up with the big chains. Since you're a Redpanda user, you have access to state of the art streaming tech to build real-time data systems. Specifically, you have access to the core streaming data platform, and also an integration platform called Redpanda Connect.

Combining these systems, you'll be able to build an order-tracking and notification system with less code and less operational headaches than the competition. Let's get started.

# Design
Our system will provide real-time tracking for pizza orders, allowing customers to monitor their order status and track the delivery in real time. The system follows an event-driven architecture using Redpanda for handling order status updates, tracking, and notifications.

Like many organizations, we assume the orders are placed in a transactional database on the "operations" side of the house. Our goal is to move data from this transactional database into Redpanda, where we can process and enrich it in near real-time. For example, if our transactional system (Postgres) captures this order:

| order_id | customer_id | customer_name | customer_address |             details              | order_status |          created_at           |
|----------|-------------|---------------|------------------|----------------------------------|--------------|-------------------------------|
|    1     |      1      | John Doe      | 123 Main St      | 2 cheese pizzas, 1 garlic bread  |   delivering | 2024-12-12 17:25:52.723261+00 |

We want to:

- Scrub the data of sensitive information.
- Determine if the order status has changed recently.
- Conditionally send a personalized notification using AI.

An example notification that we may produce from the above record is shown here:

```json
{
  "customer_id": 1,
  "details": "2 cheese pizzas, 1 garlic bread",
  "message": "Hey there! 🍕 Your 2 cheese pizzas and 1 garlic bread are on the move. They're just as"
             "excited as you are and can't wait to make a grand cheesy entrance at your place. Stay "
             "tuned for the deliciousness ahead! 🚚🍞",
  "order_id": 1,
  "order_status": "pending",
  "previous_status": "none"
}
```

There are a few moving parts here, including a database, Redpanda, and Redpanda Connect. But we have already pre-configured these services for you in a Docker compose environment.

You can start all of the services needed for this tutorial with the following command.

```sh
docker-compose up -d
```

Once the services are running, Redpanda console will be available at: [http://localhost:8080](http://localhost:8080). We won't use the UI too much in this tutorial. Instead, you'll be mostly interacting with Redpanda from the commandline.

To do this, set the following alias so that any invocation of `rpk`(Redpanda's commandline interface) uses the pre-installed version in your local Redpanda cluster:

```sh
alias rpk="docker exec -ti redpanda-1 rpk"
```

Next, you'll setup the Redpanda topics.

## Topic setup
Before you start reading order data from Postgres into Redpanda, you need someplace to put it. Therefore, the very first thing we need to do is create a topic to hold all of the order events. The events will look something like this.

```json
{
  "order_id": "",
  "customer_id": "",
  "customer_name": "",
  "customer_address": "",
  "details": "",
  "order_status": "",
  "created_at": "",
}
```

Now, the big question that most beginners have trouble with is deciding on a partition count. You're still growing your customer base so you don't have a good grasp of your volume, but planning for the future and using the powers of 2 rule, we'll select a reasonable number of 4 partitions. Yeah we could overthink it, but we're in the pizza business so lets roll with it.

<sub>Many beginners get tripped up when selecting partition counts. There are some calculators online to help you choose a count, but using powers of 2 (e.g. 4,8,16,32,64,128, …) is a good starting point. It often aligns with CPU architectures / core count, is useful for core-level load balancing, and also aligns with memory and cache structures. In our case, we'll choose 4 because our small pizza shop won't produce that much data. If we were Dominos, we might start with 64 or higher.</sub>

 
There are several CLIs in the Kafka ecosystem, but `rpk` is extremely powerful 🔥, so we'll use that. Run the following command to create your topic.

```
rpk topic create orders -p 4
```

## Capturing orders
When orders come in, they are written directly to the company's main transactional database: Postgresql. In fact, you can see some orders are already in the database:

```sh
docker exec -ti postgres psql -c "select * from orders"
```

The goal is to get this data into Redpanda so you can monitor order updates and notify your hungry customers. You have a few options, including:

- Producing the data directly from the backend application that processes orders
- Using Redpanda Connect to pull records directly from Postgresql, automatically producing the data to Redpanda

Since we not only need to move the data, but also need to do some processing on it before it hits the Redpanda topic, we'll go with the second option.

First, create a file called `connect.yaml`. This file will contain data pipeline definitions, written in YAML, to tell Redpanda where to pull data from, how to transform it, and where to send it to.

Start by adding a single input to `connect.yaml`, which tells Connect to read data from the `orders` table.

```yaml
input:
  sql_select:
    driver: postgres
    dsn: postgres://root:secret@postgres:5432/root?sslmode=disable
    table: orders
    columns: [ '*' ]
```

Each `input`, `output`, and `processor` in Connect has different configuration parameters. These are well documented in [the Redpanda documentation](https://docs.redpanda.com/redpanda-connect/components/inputs/sql_select/), so if something doesn't seem intuitive, please check out the docs.

Now, see if the input works by running the following `rpk connect` command.

```sh
rpk connect run /etc/redpanda/connect.yaml
```

You should see some orders get printed to the screen. This is a good start, but we want the orders data in Redpanda. You can see that the `orders` topic is empty by running this command:

```sh
rpk topic consume orders
```

The command will just hang, waiting for data to flow through the topic. Go ahead and hit `Ctrl + C` to exit.

If you're more of a UI person, you could also hop on over to Redpanda Console and look at the topic. It will be empty.
[http://localhost:8080/topics/orders](http://localhost:8080/topics/orders).

Let's hydrate the topic now by adding a Kafka output. Open the `connect.yaml` file again and run the following code, which tells Redpanda Connect to send the data to the `orders` topic in our Redpanda cluster.

```yaml
input:
  sql_select:
    driver: postgres
    dsn: postgres://root:secret@postgres:5432/root?sslmode=disable
    table: orders
    columns: [ '*' ]

# add the output
output:
  label: "redpanda"
  kafka:
    addresses: [ 'redpanda-1:9092']
    topic: orders
    key: '${! json("customer_id") }'
```

We're using the `customer_id` as the record key (see the last line) since we want all events for a given customer to be ordered. To deploy these changes, run the following command:

```sh
rpk connect run /etc/redpanda/connect.yaml
```

Then, verify that the data is now in Redpanda. You can do that from the CLI:

```sh
rpk topic consume orders
```

or from [Redpanda Console](http://localhost:8080/topics/orders).

You should see data flowing through Redpanda now. As they say in the pizza industry, "Now we're cooking with gas!" 🔥

You now know the basics of moving data between various input and output destinations using Redpanda Connect. In other words, the important "extract" and "load" steps in your traditional ETL or ELT pipelines.

In the next section, we'll explore one of Redpanda Connect's biggest strengths: its processing layer.

## Transforming data with Redpanda Connect

Now that data is flowing through Redpanda, you may have noticed that some sensitive customer information is included in each payload. Namely, the customer's name and address:

```json
{
  "created_at": "2024-12-12T17:25:52.724229Z",
  "customer_address": "456 Oak Ave",
  "customer_id": 2,
  "customer_name": "Jane Smith",
  "details": "1 pepperoni pizza, 1 veggie pizza",
  "order_id": 2,
  "order_status": "delivered"
}
```

Our order tracking system doesn't actually need this information, so let's add some lightweight stream processing to remove this sensitive information. How do we do this?

Well, just like pizza, Redpanda Connect is a system of many layers. Sandwiched between input and output configurations, can use something `pipelines` to perform one or more data processing steps. At a high-level, the syntax looks like this:

```yaml
input:
  ...

pipeline:
  processors:
    ...

output:
  ...
```

Within each `pipeline`, we have one or more `processors`, which define the data processing logic. There are nearly [100 processors](https://docs.redpanda.com/redpanda-connect/components/processors/about/), covering a wide range of use cases, from filtering and transforming data, to enriching it with external sources, aggregating records, or even creating [advanced workflows](https://docs.redpanda.com/redpanda-connect/components/processors/workflow/). You are only limited by your imagination.

While covering every processor is not possible in just a short tutorial, we will explore a few powerful options. Perhaps the most flexible and powerful processor is `bloblang`, a dynamic and expressive language for filtering, transforming, and mapping data. With `bloblang`, you can manipulate fields, enrich messages, and even create complex conditional logic, making it an essential tool for customizing pipelines to fit your specific needs.

The core features can be found in [the Redpanda Connect documentation](https://docs.redpanda.com/redpanda-connect/guides/bloblang/about/), but the goal of the `bloblang` processor is to simply map an input document into a new output document. This is perfect for our current use case of cleansing the input record of sensitive information.

The bloblang syntax for creating a new `orders` document with the sensitive information removed is shown here:

```yaml
pipeline:
  processors:
    - bloblang: |
        root = {}
        root.customer_id = this.customer_id
        root.order_id = this.order_id
        root.order_status = this.order_status
        root.details = this.details
```

We start by creating an empty document `{}` called `root`. Then, we transfer the non-sensitive fields (`customer_id`, `order_id`, `order_status`, `details`) from the current document (`this`) to the new document (`root`). Go ahead and replace `connect.yaml` with the following code to see this in action.

```yaml
input:
  sql_select:
    driver: postgres
    dsn: postgres://root:secret@postgres:5432/root?sslmode=disable
    table: orders
    columns: [ '*' ]

# add the pipeline
pipeline:
  processors:
    - bloblang: |
        root = {}
        root.customer_id = this.customer_id
        root.order_id = this.order_id
        root.order_status = this.order_status
        root.details = this.details

output:
  label: "redpanda"
  kafka:
    addresses: [ 'redpanda-1:9092']
    topic: orders
    key: '${! json("customer_id") }'
```

Then, run the pipeline again with the following command:

```sh
rpk connect run /etc/redpanda/connect.yaml
```

Finally, verify that the order data has now been scrubbed:

```
rpk topic consume orders -f '%v' -n 1 -o -1 | jq '.'
```

The output will show records that are cleaner and more privacy-friendly.

```json
{
  "customer_id": 3,
  "details": "3 meat lovers pizzas",
  "order_id": 3,
  "order_status": "preparing"
}
```

As we've discussed in other Redpanda University courses, this type of operation which operates on a single record at a time is called a **stateless operation**. These are among the simplest and most common stream processing tasks that you'll see in the wild. Later in this tutorial, you'll get some experience with more complicated **stateful operations**, which remember data they've seen before. But first, let's take a quick look at testing so that we can continue to iterate on this pipeline confidently.

## Testing
As you build Redpanda Connect pipelines, it's a good idea to add tests to prevent accidental regressions or bugs in your code. Luckily, unit tests can be written using a simple, declarative syntax, right alongside your YAML definitions. The following example demonstrates a simple test case for the record-scrubbing pipeline we just created. Just add this to the end of the `connect.yaml` file.

```yaml
tests:
  - name: test record scrubbing
    environment: {}
    input_batch:
      - content: |
          {
            "created_at": "2024-12-12T17:25:52.724229Z",
            "customer_address": "456 Oak Ave",
            "customer_id": 2,
            "customer_name": "Jane Smith",
            "details": "1 pepperoni pizza, 1 veggie pizza",
            "order_id": 2,
            "order_status": "delivered"
          }
    output_batches:
      -
        - json_equals: |
            {
              "customer_id": 2,
              "details": "1 pepperoni pizza, 1 veggie pizza",
              "order_id": 2,
              "order_status": "delivered"
            }
```

By specifying one or more input records, and then asserting the contents of the output record, we can ensure our code performs the task we expect it to. Go ahead and update your `connect.yaml` with this code, so that the full file looks like this:

```yaml
input:
  sql_select:
    driver: postgres
    dsn: postgres://root:secret@postgres:5432/root?sslmode=disable
    table: orders
    columns: [ '*' ]

# add the pipeline
pipeline:
  processors:
    - bloblang: |
        root = {}
        root.customer_id = this.customer_id
        root.order_id = this.order_id
        root.order_status = this.order_status
        root.details = this.details

output:
  label: "redpanda"
  kafka:
    addresses: [ 'redpanda-1:9092']
    topic: orders
    key: '${! json("customer_id") }'

tests:
  - name: test record scrubbing
    environment: {}
    input_batch:
      - content: |
          {
            "created_at": "2024-12-12T17:25:52.724229Z",
            "customer_address": "456 Oak Ave",
            "customer_id": 2,
            "customer_name": "Jane Smith",
            "details": "1 pepperoni pizza, 1 veggie pizza",
            "order_id": 2,
            "order_status": "delivered"
          }
    output_batches:
      -
        - json_equals: |
            {
              "customer_id": 2,
              "details": "1 pepperoni pizza, 1 veggie pizza",
              "order_id": 2,
              "order_status": "delivered"
            }
```

To run the test, you can use `rpk`. For example, run the following command:

```sh
rpk connect test /etc/redpanda/connect.yaml
```

You'll see the following output printed to the screen:

```
Test '/etc/redpanda/connect.yaml' succeeded
```

For larger pipelines, you may want to break out your tests into a separate file. This is also supported, and you can find more information in [the official documentation](https://docs.redpanda.com/redpanda-connect/configuration/unit_testing/#writing-a-test). For simplicity, we'll just keep everything in a single file for this tutorial.

## More Operators
It may seem like we're hopping around a bit, but the four concepts you've learned so far (inputs, outputs, pipelines, and testing) will allow you to explore the rest of Redpanda Connect's features with ease. The testing piece is especially important since it will allow you to confirm your expectations and assumptions in a quick iteration loop as you develop. This will be useful in the next section as we introduce a more complex feature: notifying customers when their order status changes.

### Stateful Resources
A key feature of our pizza tracker is its ability to proactively notify customers as their orders progress through various stages. No more anxiously refreshing a browser or hovering over a screen wondering when their extra cheese pizza will show up at the door.

While this may seem like a straightforward feature, implementing it requires some of the more advanced capabilities of Redpanda Connect.

To meet the requirements, our pizza tracking pipeline needs to accomplish the following:

- For each incoming record, determine if the status of the given order has changed.
- If the status remains the same, take no action to avoid sending unnecessary notifications.
- If the status has changed, trigger a notification to the customer. For now, this will be simulated by logging a message.

To achieve this, the pipeline must remember previously-seen events. This "awareness" or memory of previously-seen events will make our application **stateful**.

A simple key-value store or cache is well-suited for this purpose. Each time a status update is received, the pipeline will check the cache for the previous status associated with the order ID. If a change is detected, it will log the notification. Additionally, the cache will be updated with the latest status to ensure future records are processed correctly.

Luckily for us, Redpanda Connect includes `cache` processors and resources to facilitate this. To define a cache resource, you can add the following line to your `connect.yaml` file:

```yaml
cache_resources:
  - label: order_cache
    memory:
      default_ttl: 1800s
```

Here, we are choosing an in-memory cache with a time-to-live of 1800 seconds (or 30 minutes) timeout. However, more durable options like Redis, Memcached, and Dynamodb are [also available](https://docs.redpanda.com/redpanda-connect/components/caches/about/). You are now ready to update your pipeline to retrieve and store order statuses within this cache resource.

### Using Caches
With the cache resource defined, your pipeline can now check for previous order statuses whenever an update comes in. This will help us determine if a customer's order status has changed and, if so, send a notification to the customer.

First, let's define some test cases that demonstrate the expected behavior. This approach of writing tests before code is called test-driven development.

The input messages are defined using the `input_batch` configuration, and the expected outputs, which include a new field for tracking the previous order status (`previous_status`), are defined with the `output_batches` configuration. Go ahead and replace the `tests` section of your `connect.yaml` file with the following:

```yaml
tests:
  - name: test record scrubbing
    environment: {}
    input_batch:
      - content: |
          {
            "created_at": "2024-12-12T17:25:52.724229Z",
            "customer_address": "456 Oak Ave",
            "customer_id": 2,
            "customer_name": "Jane Smith",
            "details": "1 pepperoni pizza, 1 veggie pizza",
            "order_id": 2,
            "order_status": "pending"
          }
      - content: |
          {
            "created_at": "2024-12-12T17:25:52.724229Z",
            "customer_address": "456 Oak Ave",
            "customer_id": 2,
            "customer_name": "Jane Smith",
            "details": "1 pepperoni pizza, 1 veggie pizza",
            "order_id": 2,
            "order_status": "pending"
          }
      - content: |
          {
            "created_at": "2024-12-12T17:25:52.724229Z",
            "customer_address": "456 Oak Ave",
            "customer_id": 2,
            "customer_name": "Jane Smith",
            "details": "1 pepperoni pizza, 1 veggie pizza",
            "order_id": 2,
            "order_status": "delivered"
          }
    output_batches:
      -
        - json_equals: |
            {
              "customer_id": 2,
              "details": "1 pepperoni pizza, 1 veggie pizza",
              "order_id": 2,
              "order_status": "pending",
              "previous_status": "none"
            }
        - json_equals: |
            {
              "customer_id": 2,
              "details": "1 pepperoni pizza, 1 veggie pizza",
              "order_id": 2,
              "order_status": "pending",
              "previous_status": "pending"
            }
        - json_equals: |
            {
              "customer_id": 2,
              "details": "1 pepperoni pizza, 1 veggie pizza",
              "order_id": 2,
              "order_status": "delivered",
              "previous_status": "pending"
            }
```

If you run the tests now:

```sh
rpk connect test /etc/redpanda/connect.yaml
```

You will see a failure since your pipeline isn't actually populating the new `previous_status` field yet.

```sh
Test '/etc/redpanda/connect.yaml' failed

Failures:

--- /etc/redpanda/connect.yaml ---

test record scrubbing [line 26]:
batch 0 message 0: json_equals: JSON content mismatch
{
    "customer_id": 2,
    "details": "1 pepperoni pizza, 1 veggie pizza",
    "order_id": 2,
    "order_status": "pending",
    "previous_status": "none"
}
```

This is expected since you haven't updated the pipeline yet. Let's do that now so that you can hydrate the new field using the new cache resource.


### Using the branch operator
Each step in a Redpanda Connect pipeline modifies the source message it processes, so if you were to add another step immediately following the `bloblang` processor, that step would operate on the output of the entire `bloblang` transformation.

However, to perform a lookup on the cache, you need to extract a single field from the payload and use that as the input for the lookup, without modifying the entire message. Using the `branch` operator, you can create a nested pipeline to handle the extracted data independently while keeping the main pipeline unaffected.

For example, to perform a cache lookup using the `order_id`, you can configure the `branch` operator as follows:

```yaml
pipeline:
  processors:
     ...

      # Retrieve the previous status from the cache
      - branch:
          processors:
            # Since cache misses are logged as errors, wrap the cache.get operation in a try/catch
            # to reduce error log noise
            - try:
              - cache:
                  # lookup the previous status for this order_id in our order_cache resource,
                  # which is an in-memory map. The in-memory map can be replaced with Redis
                  # or more durable storage in production
                  resource: order_cache
                  operator: get
                  key: '${! json("order_id") }'
            - catch:
              # If the order_id isn't in the cache, set the previous status to "none"
              - mapping: |
                  "none"
          # This part of the branch operator allows us to map the results of this operation
          # back to the original source message
          result_map: |
            root.previous_status = content().string()
```

The code is heavily commented, so to understand the processor's configuration in more detail, please read through the comments before proceeding.

### Writing to the cache
Awesome! You're performing lookups on the cache now, but your tests are still failing. Why? Well, if you don't actually write the order statuses to the cache when they come in, the cache resource will always be empty.

Therefore, after retrieving the previous status for the current order, you need to make sure to write the current status to the cache. To do this, you can use the `cache` processor again. This time, you'll use the `set` operator to write to the cache.

Add the following processor to the `pipeline`, right after the `try` / `catch` processors.

```yaml
  # Update the cache with the latest order status
  - cache:
      resource: order_cache
      operator: set
      key: '${! json("order_id") }'
      value: '${! json("order_status") }'
```

Now, your tests should pass.

```sh
rpk connect test /etc/redpanda/connect.yaml
```

### Notifying customers
Your cache is working, which means your application can now tell if the status of an order has changed. The next step is to notify the customers whenever an order is updated.

There are different ways to notify customers, and full exploration of each option is beyond the scope of this tutorial. However, one approach is to make an HTTP request to a dedicated notification service. For example, you could use the `http` processor to issue a `POST` request, as follows.

```yaml
      # Perform an action if the status has changed
      - branch:
          request_map: 'if this.status_changed { this }'
          processors:
            - http:
                url: "http://localhost:8787/api/status-change"
                method: POST
                headers:
                  Content-Type: application/json
                payload: |
                  {
                    "customer_id": this.customer_id,
                    "order_id": this.order_id,
                    "previous_status": this.previous_status,
                    "new_status": this.order_status
                  }
```

For the purpose of this tutorial, however, we will use the `log` operator to simply print a message each time a customer should be notified. This allows us to build the rest of the application without focusing on the implementation details of a separate HTTP service.

To achieve this, add the following line to your `pipeline` config"

```yaml
  - branch:
      request_map: 'if this.previous_status != this.order_status { this }'
      processors:
        - log:
            level: INFO
            message: |
              Let customer ${! json("customer_id") } know their order is now: ${! json("order_status") }
```

<sub>See connect-8.yaml for the full file.</sub>

If you re-run the pipeline with the following command:

```sh
rpk connect run /etc/redpanda/connect.yaml
```

You should see several logs like the following:

```sh
INFO Let customer 1 know their order is now: baking
INFO Let customer 2 know their order is now: delivering
INFO Let customer 4 know their order is now: pending
INFO Let customer 3 know their order is now: preparing
INFO Let customer 5 know their order is now: delivered
```

### Personalization and AI (Bonus)
In this bonus section, we'll go a little bit deeper to introduce you to `secrets` and also some of the AI processors. It will require an OpenAI API key, which you can create [here](https://platform.openai.com/api-keys). However, if you don't want to create an API key, feel free to skim through or skip this section.

Your goal in this section is to add some personalization to the notifications. Specifically, you'll use the OpenAI chat completion processor to create personalized notifications for your customers when their order status changes.

The simplest way to do this is to add the `openai_chat_completion` processor to your pipeline. Replace the log processor from the last section with the following:

```yaml
pipeline:
  processors:
      ...

      # Add some personalization
      - label: openai
        branch:
          request_map: 'if this.previous_status != this.order_status && this.previous_order.status != "none" { this }'
          processors:
            - try:
                # Use an external AI model to add personalization our notications
                -   openai_chat_completion:
                    server_address: https://api.openai.com/v1
                    api_key: "${OPENAI_API_KEY}"
                    model: gpt-4o
                    # Feel free to adjust this prompt in fun ways. Maybe provide a fun persona
                    # for OpenAI to use when generating text?
                    system_prompt: |
                      Our customer just ordered some food and the order status just changed
                      from to ${! json(this.order_status)}. Please create a personalized message
                      to give them this update.
                      Bonus points if you can come up with something witty pertaining to their
                      order: ${! json(this.details)}.
            - catch:
              # If the order_id isn't in the cache, set the previous status to "none"
              - mapping: |
                  "Your order is now: " + this.order_status
          result_map: 'root.message = content().string()'

      # Perform an action if the status has changed
      - branch:
          request_map: 'if this.message != null { this }'
          processors:
            - log:
                level: INFO
                message: |
                  Send customer update: ${! json("customer_id") }
                  ${! json("message") }
```

If you look closely at the `api_key` configuration, you'll see a placeholder:

```yaml
api_key="${OPENAI_API_KEY}"
```

You could add your [OpenAI API key](https://platform.openai.com/api-keys) or other sensitive information directly to your configuration files, but that's not a secure practice. Instead, the syntax we're using (`${ENV_VAR_NAME}`) tells Redpanda Connect to inject that value from the environment.


To run this pipeline now with the current environment variable, execute the following command:

```sh
export OPENAI_API_KEY=...
docker exec -e OPENAI_API_KEY=$OPENAI_API_KEY -ti redpanda-1 \
  rpk connect run /etc/redpanda/connect.yaml
```

You'll see several customer notifications get logged to the screen. If you consume from the orders topic now:

```sh
rpk topic consume orders -f '%v' -n 1 -o -1 | jq '.'
```

You'll see personalized messages like the following:

```json
{
  "customer_id": 1,
  "details": "2 cheese pizzas, 1 garlic bread",
  "message": "Greetings, Pizza Connoisseur! Your cheesy dreams have just come true 🍕"
             "Your 4 cheese pizzas and 2 sodas have been delivered",
  "order_id": 1,
  "order_status": "delivered",
  "previous_status": "none"
}
```

That's amazing. Your new AI-powered pizza is now positioned for success. You can finally start making those BBQ chicken pizzas you love so much, or just go find and investor to dump $15M into your new AI pizza start up :)

### Summary
We've barely scratched the surface of what you can do in Redpanda Connect, but the workflows for adding inputs, outputs, and processors, as well as running unit tests, adding cache resources, and independent branch operations to access the cache, will provide a good foundation for you to continue exploring Redpanda Connect.

Before you close this tutorial, we encourage to take a look at the [other processors](https://docs.redpanda.com/redpanda-connect/components/processors/about/) and pipeline building resources in the official documentation. Perhaps add a new operator to challenge your knowledge and get some self-guided experience. Until next time, keep learning and have fun with Redpanda.

