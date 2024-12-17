CREATE TABLE orders (
    order_id        SERIAL PRIMARY KEY,      -- Unique order identifier
    customer_id     INTEGER NOT NULL,        -- Unique customer identifier
    customer_name   VARCHAR(255) NOT NULL,   -- Name of the customer
    customer_address VARCHAR(255) NOT NULL,  -- Address of the customer
    details         TEXT NOT NULL,           -- Details of the order (e.g., type of pizzas)
    order_status    VARCHAR(50) NOT NULL,    -- Status of the order (e.g., pending, delivered)
    created_at      TIMESTAMPTZ DEFAULT NOW() -- Timestamp when the order was placed
);

-- Inserting 5 example orders into the orders table
INSERT INTO orders (customer_id, customer_name, customer_address, details, order_status)
VALUES (1, 'John Doe', '123 Main St', '2 cheese pizzas, 1 garlic bread', 'baking');

INSERT INTO orders (customer_id, customer_name, customer_address, details, order_status)
VALUES (2, 'Jane Smith', '456 Oak Ave', '1 pepperoni pizza, 1 veggie pizza', 'delivering');

INSERT INTO orders (customer_id, customer_name, customer_address, details, order_status)
VALUES (3, 'Michael Brown', '789 Pine Rd', '3 meat lovers pizzas', 'preparing');

INSERT INTO orders (customer_id, customer_name, customer_address, details, order_status)
VALUES (4, 'Emily Davis', '321 Cedar St', '1 margherita pizza, 1 salad', 'pending');

INSERT INTO orders (customer_id, customer_name, customer_address, details, order_status)
VALUES (5, 'Chris Wilson', '654 Spruce St', '4 cheese pizzas, 2 sodas', 'delivered');
